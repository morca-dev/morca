"""Alerts to a person: a push to the owner's phone through ntfy (#184).

A problem is otherwise only visible in the UI. These are raised where
they're decided (the watchdog's trip, a run failing after its last retry, a
fill that stopped moving, the control host's disk, a worker that went quiet,
and `morca notify` from a shell script such as the nightly backup) and sent
as one HTTP POST of plain text to an ntfy topic URL, with the headers ntfy
reads:

    Title, Priority (high | default | low), Tags, Click (the UI's link)

**Settings.** None of these is logged, and none is ever in a message.

| Variable | Meaning |
|---|---|
| `MORCA_NOTIFY_URL` | a topic URL (`https://ntfy.sh/<long-random-topic>`), or just a server (`https://ntfy.example.com`) when the topic comes from the secret. Unset, and no `MORCA_NOTIFY_SECRET`: no alerts. |
| `MORCA_NOTIFY_SECRET` | the id of a secret, read with `MORCA_SECRET_FETCH` (`morca._internal.control.fetch_secret`), holding the topic: a name (appended to `MORCA_NOTIFY_URL`, else `https://ntfy.sh`), or a whole URL. The topic is a secret in practice (anyone who knows it can read it). |
| `MORCA_NOTIFY_TOKEN`, `MORCA_NOTIFY_TOKEN_SECRET` | an ntfy access token for a protected topic, plain or as a secret's id. |
| `MORCA_NOTIFY_MIN_SECONDS` | 1800: the same alert (kind and subject) is sent at most once per period. |
| `MORCA_NOTIFY_TIMEOUT_MS` | 5000: how long a send may take. |
| `MORCA_NOTIFY_FILL_STALL_HOURS` | 2: see `morca._internal.scheduler`. |
| `MORCA_NOTIFY_DISK_PERCENT` | 85: the control host's fullest disk. |
| `MORCA_NOTIFY_WORKER_SECONDS` | 300: a worker holding runs, quiet for this long. |
| `MORCA_UI_URL` | where `Click` goes (`<MORCA_UI_URL>/runs/<id>`, `/ops/control`). |

**Dedup and retries are in Postgres** (`orca.notifications`, a row per kind
and subject), so a restart doesn't send again. `alert` records the alert as
firing and tries to send it; one that failed stays pending and `flush`, which
the scheduler calls on every tick, tries it again after a wait that doubles
(30 seconds, up to 15 minutes). A send is one POST with a bounded timeout and
no retry of its own, and a failure is logged without the URL, so a down ntfy
costs the scheduler at most one timeout a tick, and never an exception.
`resolve` sends a low-priority 'resolved' once, for an alert that was sent.

**Each one is kept** (`orca.alerts`, Ops › Alerts): a row per alert raised
and per 'resolved', with its words, its link, the pipelines and run it is
about, whether it was delivered (`delivery`: pending, sent, or dropped when
a newer one replaced it before it went, with the last error of a try that
failed) and, on a raised one, when it resolved (`resolved_at`, and the row
that resolved it, or a later raise of the same alert). Held-back alerts
aren't sent, so they have no row. Kept 90 days.
"""

from std.os import getenv

from objectstore.http import Header, HttpClient
import morca._internal.db.notify as notify_db

from morca._internal.control import fetch_secret
from morca._internal.html import Html
from morca._internal.json import quote
from morca._internal.state import State

comptime DEFAULT_MIN_SECONDS = 1800
comptime DEFAULT_SERVER = "https://ntfy.sh"
comptime _FLUSH_BATCH = 5


def _number(name: String, default: Int) -> Int:
    var v = getenv(name)
    if not v:
        return default
    try:
        return Int(Float64(v))
    except:
        return default


def min_seconds() -> Int:
    """`MORCA_NOTIFY_MIN_SECONDS`: how long the same alert is held back."""
    return _number("MORCA_NOTIFY_MIN_SECONDS", DEFAULT_MIN_SECONDS)


def configured() -> Bool:
    """Whether alerts are on: the URL or the secret naming the topic is set.
    Reads only the environment (the secret is read when sending)."""
    return getenv("MORCA_NOTIFY_URL").byte_length() > 0 or (
        getenv("MORCA_NOTIFY_SECRET").byte_length() > 0
    )


def ui_link(path: String) -> String:
    """`path` on the UI at `MORCA_UI_URL`, or empty when that isn't set."""
    var base = String(getenv("MORCA_UI_URL").rstrip("/"))
    if not base:
        return String()
    return String(base, path)


@fieldwise_init
struct Target(Movable):
    """Where to send, and the token to send with. Never printed."""

    var url: String
    var token: String


def target() raises -> Target:
    """The topic URL and token from the settings, reading the secrets. The
    errors say which setting, never a value."""
    var base = String(getenv("MORCA_NOTIFY_URL").strip())
    var url = base
    var secret = getenv("MORCA_NOTIFY_SECRET")
    if secret:
        var topic: String
        try:
            topic = String(fetch_secret(secret).strip())
        except:
            raise Error("can't read the secret MORCA_NOTIFY_SECRET names")
        if not topic:
            raise Error("the secret MORCA_NOTIFY_SECRET names is empty")
        if "://" in topic:
            url = topic
        else:
            url = String(
                (base if base else String(DEFAULT_SERVER)).rstrip("/"),
                "/",
                topic,
            )
    if not url:
        raise Error("no MORCA_NOTIFY_URL or MORCA_NOTIFY_SECRET")
    if not (url.startswith("https://") or url.startswith("http://")):
        raise Error("the notify URL isn't http or https")
    var token = String(getenv("MORCA_NOTIFY_TOKEN").strip())
    var token_secret = getenv("MORCA_NOTIFY_TOKEN_SECRET")
    if not token and token_secret:
        try:
            token = String(fetch_secret(token_secret).strip())
        except:
            raise Error("can't read the secret MORCA_NOTIFY_TOKEN_SECRET names")
    return Target(url^, token^)


def _header_text(s: String, limit: Int) -> String:
    """`s` for a header: one line of ASCII (ntfy's headers are), cut."""
    var out = String()
    var n = 0
    for b in s.as_bytes():
        if n >= limit:
            break
        var c = Int(b)
        out.write("?" if c >= 0x7F else (" " if c < 0x20 else chr(c)))
        n += 1
    return out^


def post(
    t: Target,
    title: String,
    body: String,
    priority: String,
    tags: String,
    click: String,
) raises:
    """One POST to ntfy. Raises a message that holds neither the URL nor the
    token: `HTTP <status>` for a refusal, else that it couldn't connect."""
    var h: List[Header] = [
        Header("Content-Type", "text/plain; charset=utf-8"),
        Header("User-Agent", "morca-notify"),
        Header("Title", _header_text(title, 200)),
        Header(
            "Priority", _header_text(priority if priority else "default", 20)
        ),
    ]
    if tags:
        h.append(Header("Tags", _header_text(tags, 100)))
    if click:
        h.append(Header("Click", _header_text(click, 500)))
    if t.token:
        h.append(Header("Authorization", String("Bearer ", t.token)))
    var http = HttpClient()
    http.follow_redirects = False
    http.verify_tls = True
    http.timeout_ms = _number("MORCA_NOTIFY_TIMEOUT_MS", 5000)
    var status: Int
    try:
        status = http.request("POST", t.url, h, body.as_bytes()).status
    except:
        raise Error("can't reach the ntfy server")
    if status < 200 or status >= 300:
        raise Error("HTTP ", status)


def send_now(
    title: String,
    body: String,
    priority: String = "default",
    tags: String = "",
    click: String = "",
) raises:
    """Sends at once, without Postgres: `morca notify test`, and the fallback
    of `morca notify` when the database isn't there."""
    post(target(), title, body, priority, tags, click)


# ---------------------------------------------------------------------------
# Dedup and retries (Postgres)
# ---------------------------------------------------------------------------


def alert(
    mut db: State,
    kind: String,
    subject: String,
    priority: String,
    tags: String,
    title: String,
    body: String,
    click: String = "",
    pipelines: String = "",
    run: Int = 0,
) raises -> Bool:
    """Records the alert `kind` about `subject` as firing and sends it, unless
    the same one was sent in the last `min_seconds()` (or is pending). Returns
    whether it will be sent (now, or by a later `flush`). `pipelines` (comma
    separated) and `run` are what it is about, for its row on Ops › Alerts.
    Never raises for a send that fails; Postgres errors do."""
    if not configured():
        return False
    var m = notify_db.Message(title, body, priority, tags, click)
    var st = notify_db.state_of(db.conn, kind, subject, Float64(min_seconds()))
    if st:
        ref r = st.value()
        if r.state == "firing" and r.pending:
            # Not delivered yet: the newest words, on the same schedule.
            notify_db.reword_pending(db.conn, kind, subject, m)
            return True
        if r.recent:
            return False
    notify_db.fire(db.conn, kind, subject, m)
    var id = _record(
        db,
        kind,
        subject,
        "raised",
        title,
        body,
        priority,
        tags,
        click,
        pipelines,
        run,
    )
    # An earlier raise of it still open is repeated by this one.
    notify_db.resolve_older_raises(db.conn, kind, subject, id)
    _ = flush(db)
    return True


def _record(
    mut db: State,
    kind: String,
    subject: String,
    event: StaticString,
    title: String,
    body: String,
    priority: String,
    tags: String,
    click: String,
    pipelines: String = "",
    run: Int = 0,
) raises -> Int64:
    """A row of `orca.alerts` for an alert raised or resolved, waiting to be
    sent; the earlier ones of its kind and subject that hadn't gone are
    dropped, since `orca.notifications` now holds this one instead. Returns
    its id."""
    notify_db.drop_pending(
        db.conn, kind, subject, "replaced before it was sent"
    )
    return notify_db.add_alert(
        db.conn,
        kind,
        subject,
        String(event),
        notify_db.Message(title, body, priority, tags, click),
        pipelines,
        run,
    )


def is_firing(mut db: State, kind: String, subject: String) raises -> Bool:
    """Whether an alert of this kind and subject was raised and not yet
    resolved."""
    return notify_db.is_firing(db.conn, kind, subject)


def firing_subjects(mut db: State, kind: String) raises -> List[String]:
    """The subjects of `kind` raised and not yet resolved."""
    return notify_db.firing_subjects(db.conn, kind)


def resolve(
    mut db: State,
    kind: String,
    subject: String,
    title: String,
    body: String,
    click: String = "",
) raises:
    """Ends a firing alert: a low-priority 'resolved' is sent once, if the
    alert itself was ever sent. Nothing for an alert that isn't firing."""
    if not configured():
        return
    var was = notify_db.mark_resolved(
        db.conn, kind, subject, title, body, click
    )
    if not was:
        return
    var pending = was.value()
    var by = Int64(0)
    if pending:
        by = _record(
            db,
            kind,
            subject,
            "resolved",
            title,
            body,
            "low",
            "white_check_mark",
            click,
        )
    else:
        notify_db.drop_pending(
            db.conn, kind, subject, "resolved before it was sent"
        )
    notify_db.resolve_raises(db.conn, kind, subject, by)
    if pending:
        _ = flush(db)


def flush(mut db: State) raises -> Int:
    """Sends the alerts that are pending and due (a few a call), and returns
    how many were sent. A send that fails is logged and tried again later; it
    never raises. Postgres errors do."""
    var due = notify_db.take_due(db.conn)
    if len(due) == 0:
        return 0
    var sent = 0
    var t = Optional[Target](None)
    var why = String()
    try:
        t = target()
    except e:
        why = String(e)
    for r in due:
        var kind = r.kind
        var subject = r.subject
        var failure = why
        if t:
            try:
                post(
                    t.value(),
                    r.message.title,
                    r.message.body,
                    r.message.priority,
                    r.message.tags,
                    r.message.click,
                )
                failure = String()
            except e:
                failure = String(e)
        if not failure:
            notify_db.sent(db.conn, kind, subject)
            sent += 1
            continue
        var attempts = r.attempts + 1
        var wait = min(30 * (1 << min(attempts - 1, 10)), 900)
        notify_db.not_sent(db.conn, kind, subject, attempts, failure, wait)
        print(
            "morca: notify:",
            kind,
            "alert not sent (",
            failure,
            "); trying again in",
            wait,
            "s",
        )
    notify_db.prune(db.conn)
    return sent


# ---------------------------------------------------------------------------
# The UI
# ---------------------------------------------------------------------------


@fieldwise_init
struct Sent(Copyable, Movable):
    var kind: String
    var subject: String
    var state: String
    var title: String
    var priority: String
    var when: String
    var ago: Int
    var pending: Bool
    var error: String


def recent(mut db: State, limit: Int = 8) raises -> List[Sent]:
    """The alerts last sent or waiting to be, newest first."""
    var out = List[Sent]()
    for r in notify_db.recent(db.conn, limit):
        out.append(
            Sent(
                r.kind,
                r.subject,
                r.state,
                r.title,
                r.priority,
                r.sent,
                r.ago,
                r.pending,
                r.error,
            )
        )
    return out^


def notify_json(on: Bool, sent: List[Sent]) -> String:
    """Whether alerts are configured and the last few; never the URL."""
    var out = String('{"configured": ', "true" if on else "false")
    out.write(', "min_seconds": ', min_seconds(), ', "recent": [')
    for i in range(len(sent)):
        ref s = sent[i]
        out.write(
            ", " if i else "",
            '{"kind": ',
            quote(s.kind),
            ', "subject": ',
            quote(s.subject),
            ', "state": ',
            quote(s.state),
            ', "title": ',
            quote(s.title),
            ', "priority": ',
            quote(s.priority),
            ', "sent": ',
            quote(s.when),
            ', "pending": ',
            "true" if s.pending else "false",
            ', "error": ',
            quote(s.error),
            "}",
        )
    out.write("]}")
    return out^


def _ago(seconds: Int) -> String:
    if seconds < 0:
        return String()
    if seconds < 90:
        return String(seconds, " s ago")
    if seconds < 5400:
        return String(seconds // 60, " min ago")
    if seconds < 172800:
        return String(seconds // 3600, " h ago")
    return String(seconds // 86400, " days ago")


def notify_html(mut h: Html, on: Bool, sent: List[Sent]):
    """Ops > Control's alerts: whether they're configured, and the last few.
    The topic is a secret, so only whether it is set is shown."""
    h.raw("<h2>Alerts</h2>")
    if not on:
        h.raw(
            (
                '<p class="muted">Not configured: set'
                " <code>MORCA_NOTIFY_URL</code>"
            ),
            " (an ntfy topic URL) to get a push when the watchdog trips, a",
            " run fails, a fill stalls, the disk fills or a worker is lost;",
            " <code>morca notify test</code> sends a test message.</p>",
        )
        return
    h.raw("<p>Alerts go to an ntfy topic (not shown: anyone who knows it can")
    h.raw(
        " read it); the same alert is sent at most once every ",
        min_seconds() // 60,
        " minutes. <code>morca notify test</code> sends a test message.</p>",
    )
    if len(sent) == 0:
        h.raw('<p class="muted">None sent yet.</p>')
        return
    h.raw(
        "<table><thead><tr><th>When</th><th>Kind</th><th>Subject</th>",
        "<th>Priority</th><th>Message</th><th>Status</th></tr></thead><tbody>",
    )
    for s in sent:
        h.raw('<tr><td title="')
        h.text(s.when)
        h.raw('">')
        h.text(_ago(s.ago) if s.ago >= 0 else String("waiting"))
        h.raw("</td>")
        h.cell(s.kind)
        h.cell(s.subject)
        h.cell(s.priority)
        h.cell(s.title)
        if s.pending:
            h.raw('<td class="bad">not sent: ')
            h.text(s.error if s.error else String("waiting"))
            h.raw("</td>")
        else:
            h.cell(String("resolved") if s.state == "resolved" else "sent")
        h.raw("</tr>")
    h.raw(
        '</tbody></table><p class="muted">Every one, with what it links to',
        (
            ' and whether it is still open: <a href="/ops/alerts">Ops ›'
            " Alerts</a>."
        ),
        "</p>",
    )
