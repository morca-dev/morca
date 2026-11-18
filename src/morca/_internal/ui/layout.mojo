"""Every page's frame (`page_html`): its head, the nav, the slots the
server fills in with who's logged in (`morca._internal.web.server`), and the scripts
every page has (`_POLL` for live fragments, `_TABS`, `_TIPS`, `_PEEK` for
code on hover); and what every page draws with: cards, facts, help, action
buttons, and the 404 and 400 pages.
"""

from std.os import getenv

from morca._internal.html import Html, escape
from morca._internal.ui.loading import LOADING_JS
from morca._internal.ui.step_cards import LEAD_JS, STEP_CARDS_JS
from morca._internal.ui.terms import header_help
from morca._internal.db.pipelines_view import comma_list


def docs_link(anchor: StaticString) -> String:
    """A small link to the docs' section, beside a heading."""
    var base = getenv("MORCA_DOCS_URL", "https://mlake.dev/s/orca/docs/")
    return String(
        ' <a class="doc" href="',
        escape(String(base, "#", anchor)),
        '" target="_blank" rel="noopener">docs</a>',
    )


comptime _POLL = """
const ago = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
const full = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "long" });
function relative(t) {
  const s = (t - Date.now()) / 1000, a = Math.abs(s);
  if (a < 45) return ago.format(Math.round(s), "second");
  if (a < 2700) return ago.format(Math.round(s / 60), "minute");
  if (a < 79200) return ago.format(Math.round(s / 3600), "hour");
  if (a < 2592000) return ago.format(Math.round(s / 86400), "day");
  if (a < 31536000) return ago.format(Math.round(s / 2592000), "month");
  return ago.format(Math.round(s / 31536000), "year");
}
function times(root) {
  for (const el of root.querySelectorAll("time.rel")) {
    const t = Date.parse(el.dateTime);
    if (isNaN(t)) continue;
    el.textContent = relative(t);
    el.title = full.format(t) + " (" + el.dateTime + ")";
  }
}
times(document);
setInterval(() => times(document), 30000);
document.addEventListener("change", (e) => {
  const t = e.target;
  if (!t.matches || !t.matches("input.pick__all")) return;
  for (const x of t.closest("table").querySelectorAll('input[name="pick"]')) x.checked = t.checked;
});
document.addEventListener("keydown", (e) => {
  const t = e.target;
  if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return;
  if (t.closest && t.closest("input, textarea, select, [contenteditable], dialog")) return;
  const a = document.querySelector(e.key === "ArrowLeft" ? 'a[rel="prev"]' : e.key === "ArrowRight" ? 'a[rel="next"]' : "x-none");
  if (a) a.click();
});
const sel = (el) => {
  const s = document.getSelection(), f = document.activeElement;
  if (f && el.contains(f) && f.matches("input, textarea, select")) return true;
  return s && !s.isCollapsed && el.contains(s.anchorNode);
};
const rowKey = (tr) => { const a = tr.querySelector("a[href]"); return a ? a.getAttribute("href") : null; };
const firstSeen = (el) => {
  for (const tr of el.querySelectorAll("tbody tr")) {
    const b = tr.getBoundingClientRect();
    if (b.bottom > 0) return b.top < window.innerHeight ? [rowKey(tr), b.top] : null;
  }
  return null;
};
for (const el of document.querySelectorAll("[data-poll]")) {
  let every = (parseFloat(el.dataset.pollEvery) || 2) * 1000;
  let timer = 0, last = null, done = false, bad = 0;
  const swap = (html) => {
    if (html === last || sel(el)) return;
    last = html;
    const open = [...el.querySelectorAll("details")].map((d) => d.open);
    const pos = [...el.querySelectorAll(".scroll, pre")].map((x) => [x.scrollLeft, x.scrollTop]);
    const seen = el.getBoundingClientRect().top < 0 ? firstSeen(el) : null;
    const ticked = new Set([...el.querySelectorAll('input[name="pick"]:checked')].map((x) => x.value));
    el.innerHTML = html;
    el.querySelectorAll('input[name="pick"]').forEach((x) => { if (ticked.has(x.value)) x.checked = true; });
    el.querySelectorAll("details").forEach((d, i) => { if (open[i]) d.open = true; });
    el.querySelectorAll(".scroll, pre").forEach((x, i) => {
      if (pos[i]) { x.scrollLeft = pos[i][0]; x.scrollTop = pos[i][1]; }
    });
    if (seen && seen[0]) {
      const tr = [...el.querySelectorAll("tbody tr")].find((t) => rowKey(t) === seen[0]);
      if (tr) window.scrollBy(0, tr.getBoundingClientRect().top - seen[1]);
    }
    times(el);
    el.dispatchEvent(new Event("morca:swap", { bubbles: true }));
  };
  const tick = async () => {
    timer = 0;
    if (done || document.visibilityState === "hidden") return;
    let r;
    try {
      r = await fetch(el.dataset.poll);
      bad = 0;
      const n = parseFloat(r.headers.get("X-Poll-Every"));
      if (n > 0) every = n * 1000;
      if (r.ok) swap(await r.text());
      if (r.status === 286) { done = true; return; }
      timer = setTimeout(tick, every);
    } catch (e) { timer = setTimeout(tick, 5000 * Math.min(2 ** bad++, 12)); }
  };
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && !timer && !done) tick();
  });
  timer = setTimeout(tick, every);
}
"""
"""What makes a page live: each element with `data-poll` is replaced every
two seconds (`data-poll-every` seconds) by what its path returns, until that answers 286 (htmx's "stop
polling"), which a fragment does once what it shows has ended. A fragment's
`X-Poll-Every` header sets the seconds until the next ask (a runs list's
newest page asks often while a run goes on, slowly otherwise). It waits while the tab is hidden and
asks at once when it's shown again, backs off when a request fails, leaves
the page alone when nothing changed, text in it is selected or a field in
it has the focus, and keeps
open `<details>` and scrolled boxes as they were, and the table row at the
top of the window where it was when rows are added above it (a row is
known by its first link) and the runs ticked for a bulk action ticked,
and tells the page
(an `morca:swap` event, so `_TABS` shows the tab chosen again). Each
`<time class="rel">` reads as how long ago it was, in the viewer's locale,
with the full local time in its tooltip; without scripts it stays UTC."""


comptime _ASK = """
(() => {
  const ask = document.getElementById("ask");
  if (!ask || typeof ask.showModal !== "function") return;
  const title = document.getElementById("ask-title"), body = document.getElementById("ask-body");
  const yes = ask.querySelector(".ask__yes"), no = ask.querySelector(".ask__no");
  let sure = null, open = null;
  const picked = (f) => {
    const all = f.elements.namedItem("all"), expect = f.elements.namedItem("expect");
    if (all && all.checked && expect) return { n: Number(expect.value), all: true };
    return { n: [...f.elements].filter((x) => x.name === "pick" && x.checked).length, all: false };
  };
  const runs = (p) => (p.all ? "all " + p.n.toLocaleString() + " runs that match" : p.n === 1 ? "1 run" : p.n + " runs");
  // The question with its {runs} and {<field>}s, or null while one is empty.
  const fill = (s, f) => {
    let empty = false;
    const out = s.replace(/[{](\\w+)[}]/g, (m, k) => {
      if (k === "runs") { const p = picked(f); if (!p.n) empty = true; return runs(p); }
      const el = f.elements.namedItem(k), v = el && el.value ? el.value.trim() : "";
      if (!v) empty = true;
      return v === "@all" ? "all partitions" : v;
    });
    return empty ? null : out;
  };
  // The same form (and button) after a live refresh replaced it.
  const twin = (f, b) => {
    const g = f.isConnected ? f : [...document.forms].find((x) => x.action === f.action && x.id === f.id && x.dataset.confirm === f.dataset.confirm);
    if (!g || !b || g.contains(b) || b.form === g) return [g, b];
    return [g, [...g.elements].find((x) => x.type === "submit" && x.name === b.name && x.value === b.value && x.textContent === b.textContent)];
  };
  document.addEventListener("submit", (e) => {
    const f = e.target, b = e.submitter;
    if (sure === f) return;
    if (!f.dataset || (b && b.formMethod === "get")) return;
    const src = b && b.dataset.confirm ? b : f.dataset.confirm ? f : null;
    if (!src) return;
    const d = src.dataset, q = fill(d.confirm, f);
    if (q === null) return;
    e.preventDefault();
    title.textContent = q;
    body.textContent = (d.confirmBody && fill(d.confirmBody, f)) || "";
    yes.textContent = d.confirmYes || (b && b.textContent.trim()) || "OK";
    no.textContent = d.confirmNo || "Go back";
    yes.classList.toggle("danger", "confirmDanger" in d);
    open = { f, b, back: b || document.activeElement };
    ask.returnValue = "";
    ask.showModal();
    no.focus();
  });
  ask.addEventListener("click", (e) => { if (e.target === ask) ask.close(""); });
  ask.addEventListener("close", () => {
    const o = open;
    open = null;
    if (!o) return;
    const [f, b] = twin(o.f, o.b);
    const back = o.back && o.back.isConnected ? o.back : b;
    if (back && back.focus) back.focus();
    if (ask.returnValue !== "yes" || !f) return;
    sure = f;
    try {
      if (f.requestSubmit) f.requestSubmit(b && b.form === f ? b : undefined);
      else {
        if (b && b.name) { const i = document.createElement("input"); i.type = "hidden"; i.name = b.name; i.value = b.value; f.append(i); }
        f.submit();
      }
    } finally { sure = null; }
  });
})();
"""
"""Asking before an action (`ask_attrs`): a form, or its submit button,
with `data-confirm` posts only once the page's one `<dialog id="ask">`
(`ASK_DIALOG`) is answered yes. The dialog shows the question, what will
happen (`data-confirm-body`) and the buttons' words (`data-confirm-yes`,
`data-confirm-no`), the yes one red for `data-confirm-danger`; `{runs}` is
how many runs the form has ticked, `{<field>}` that field's value (`@all`
reads "all partitions"); with none ticked or the field empty it doesn't
ask, and the action says what's missing. The safe button has the focus;
Escape or a click outside is no; the focus goes back to the button that
asked. Yes submits the form again with the same button, so its fields
(and the button's name and value) are posted as without scripts, which is
all a form does where scripts or `<dialog>` are missing. A GET submit
(Preview) never asks."""


comptime ASK_DIALOG = (
    '<dialog id="ask" class="ask" role="alertdialog"'
    ' aria-labelledby="ask-title" aria-describedby="ask-body">'
    '<form method="dialog" class="ask__form">'
    '<h2 id="ask-title" class="ask__title"></h2>'
    '<p id="ask-body" class="ask__body"></p>'
    '<div class="ask__btns"><button type="submit" value="no" class="ask__no"'
    ' autofocus>Go back</button><button type="submit" value="yes"'
    ' class="ask__yes">OK</button></div></form></dialog>'
)
"""The dialog `_ASK` fills in and shows, once per page."""


def ask_attrs(
    mut h: Html,
    question: String,
    body: String = "",
    yes: String = "",
    no: String = "",
    danger: Bool = True,
):
    """The attributes that make a form, or a submit button, ask
    `question` first (`_ASK`): `body` says what will happen, `yes` and
    `no` are the buttons' words (the submit button's and "Go back" if
    empty), and `danger` makes yes red."""
    h.raw(' data-confirm="')
    h.text(question)
    h.raw('"')
    if body:
        h.raw(' data-confirm-body="')
        h.text(body)
        h.raw('"')
    if yes:
        h.raw(' data-confirm-yes="')
        h.text(yes)
        h.raw('"')
    if no:
        h.raw(' data-confirm-no="')
        h.text(no)
        h.raw('"')
    if danger:
        h.raw(" data-confirm-danger")


comptime _CMD = """
for (const c of document.querySelectorAll("code[data-cmd]"))
  c.textContent = c.textContent.replaceAll("<url>", location.origin);
document.addEventListener("click", async (e) => {
  const b = e.target.closest && e.target.closest("button[data-copy]");
  if (!b) return;
  const code = b.parentElement.querySelector("code");
  try {
    await navigator.clipboard.writeText(code.textContent);
  } catch (err) {
    const r = document.createRange();
    r.selectNodeContents(code);
    getSelection().removeAllRanges();
    getSelection().addRange(r);
    b.textContent = "Press \u2318C";
    return;
  }
  b.textContent = "Copied";
  setTimeout(() => (b.textContent = "Copy"), 1500);
});
"""
"""Command boxes (`cmd_box`): `<url>` becomes the address the page was
loaded from, and Copy puts the command on the clipboard (where the
clipboard isn't allowed, it selects the text instead)."""


def cmd_box(mut h: Html, kind: String, cmd: String):
    """A shell command in a box with a Copy button; `kind` names it
    (`data-cmd`) for a script that rewrites it as a form changes."""
    h.raw('<div class="cmdbox"><pre class="cmd"><code data-cmd="')
    h.text(kind)
    h.raw('">')
    h.text(cmd)
    h.raw(
        '</code></pre><button type="button" class="copy"'
        " data-copy>Copy</button></div>"
    )


comptime _TABS = """
(() => {
  const get = (k) => { try { return localStorage.getItem(k); } catch (e) { return null; } };
  const put = (k, v) => { try { localStorage.setItem(k, v); } catch (e) {} };
  const chosen = {};
  const show = (sec, v, save) => {
    const tabs = [...sec.querySelectorAll("[role=tab][data-view]")];
    if (!tabs.some((a) => a.dataset.view === v)) return;
    for (const a of tabs) {
      a.setAttribute("aria-selected", String(a.dataset.view === v));
      const panel = document.getElementById(a.getAttribute("aria-controls"));
      if (panel) panel.hidden = a.dataset.view !== v;
    }
    if (save) { chosen[sec.dataset.tabs] = v; if (!sec.hasAttribute("data-tabs-forget")) put(sec.dataset.tabs, v); }
  };
  const init = (root) => {
    for (const sec of root.querySelectorAll("[data-tabs]")) {
      const asked = new URLSearchParams(location.search).get(sec.dataset.tabsParam);
      show(sec, chosen[sec.dataset.tabs] || asked || (sec.hasAttribute("data-tabs-forget") ? null : get(sec.dataset.tabs)), false);
    }
  };
  document.addEventListener("click", (e) => {
    const a = e.target.closest && e.target.closest("[data-tabs] [role=tab][data-view]");
    if (!a) return;
    e.preventDefault();
    show(a.closest("[data-tabs]"), a.dataset.view, true);
  });
  document.addEventListener("morca:swap", (e) => init(e.target));
  init(document);
})();
"""
"""Tabs that switch without loading the page (`data-tabs`, the key their
choice is kept under in `localStorage` unless `data-tabs-forget`, per viewer
for every page with them): each `role=tab` link with a `data-view` shows
the panel it `aria-controls`. A link's `?<data-tabs-param>=` still says
which tab to show, and without scripts the links load it."""


comptime _TIPS = """
(() => {
  let tip = null, on = null;
  const show = (el) => {
    if (!tip) {
      tip = document.createElement("div");
      tip.className = "help__tip tip";
      tip.id = "tip";
      tip.setAttribute("role", "tooltip");
      document.body.append(tip);
    }
    on = el;
    tip.textContent = el.dataset.tip;
    tip.style.display = "block";
    el.setAttribute("aria-describedby", "tip");
    const r = el.getBoundingClientRect(), w = tip.offsetWidth, h = tip.offsetHeight;
    const below = r.bottom + 6 + h <= innerHeight || r.top < h + 6;
    tip.style.top = (below ? r.bottom + 6 : r.top - h - 6) + "px";
    tip.style.left = Math.max(8, Math.min(r.left, innerWidth - w - 8)) + "px";
  };
  const hide = () => {
    if (tip) tip.style.display = "none";
    if (on) on.removeAttribute("aria-describedby");
    on = null;
  };
  const of = (t) => t && t.closest && t.closest("[data-tip]");
  document.addEventListener("mouseover", (e) => { const el = of(e.target); if (el && el !== on) show(el); });
  document.addEventListener("mouseout", (e) => { const el = of(e.target); if (el && !el.contains(e.relatedTarget)) hide(); });
  document.addEventListener("focusin", (e) => { const el = of(e.target); if (el) show(el); });
  document.addEventListener("focusout", (e) => { if (of(e.target)) hide(); });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") hide(); });
  addEventListener("scroll", hide, true);
  // A "?" in a table, which scrolls sideways: its help is fixed (CSS), so
  // not cut off by the table's box, and placed here under its button.
  const place = (h) => {
    const t = h.querySelector(".help__tip"), b = h.querySelector(".help__btn");
    if (!t || !b) return;
    const r = b.getBoundingClientRect(), w = t.offsetWidth, ht = t.offsetHeight;
    const below = r.bottom + 6 + ht <= innerHeight || r.top < ht + 6;
    t.style.top = (below ? r.bottom + 6 : r.top - ht - 6) + "px";
    t.style.left = Math.max(8, Math.min(r.left - 10, innerWidth - w - 8)) + "px";
  };
  const help = (e) => { const h = e.target.closest && e.target.closest(".scroll .help"); if (h) requestAnimationFrame(() => place(h)); };
  document.addEventListener("mouseover", help);
  document.addEventListener("focusin", help);
})();
"""
"""What a value from a fixed set means (`data-tip`, `morca._internal.ui.terms`): one
floating box, shown under the value on hover, keyboard focus (each such
value is a tab stop) or a tap, above it where there's no room, and
hidden on scroll or Escape; to a screen reader, the value's description.
And a table header's or cell's "?", whose help is placed under it."""


comptime _PEEK = """
(() => {
  const GH = /^https:[/][/]github[.]com[/]([^/]+)[/]([^/]+)[/]blob[/]([0-9a-f]{7,40})[/]([^#?]+)#L([0-9]+)$/;
  const MAX = 24;
  const files = new Map();
  const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const lead = (l) => l.length - l.trimStart().length;
  const Q3 = '"'.repeat(3);
  let box = null, cur = null, showT = 0, hideT = 0, shows = 0;
  // The file, coloured by morca (/code): its lines and their HTML.
  const load = (url) => {
    if (!files.has(url)) files.set(url, fetch("/code?u=" + encodeURIComponent(url)).then((r) => { if (!r.ok) throw new Error(r.status); return r.json(); }));
    return files.get(url);
  };
  // From the def (and its decorators) through its docstring and body, up
  // to MAX lines; it ends at the next line no deeper than the def's.
  function snippet(lines, at) {
    let from = at - 1;
    while (from > 0 && lines[from - 1].trimStart().startsWith("@")) from--;
    const indent = lead(lines[at - 1] || "");
    const out = [];
    let doc = false, i = from;
    for (; i < lines.length && out.length < MAX; i++) {
      const l = lines[i];
      if (doc) { out.push([i + 1, l]); if (l.includes(Q3)) doc = false; continue; }
      if (i > at - 1 && l.trim() && lead(l) <= indent && !")]}".includes(l.trimStart()[0])) {
        if (!l.trimStart().startsWith(Q3)) break;
        doc = l.split(Q3).length < 3;
      }
      out.push([i + 1, l]);
    }
    while (out.length && !out[out.length - 1][1].trim()) out.pop();
    return { out, more: i < lines.length && out.length >= MAX };
  }
  // The docstring that starts at line i (0-based), or null.
  const docFrom = (lines, i) => {
    if (i >= lines.length) return null;
    let t = lines[i].trimStart();
    if (t.startsWith("r" + Q3)) t = t.slice(1);
    if (!t.startsWith(Q3)) return null;
    let rest = t.slice(3), j = i;
    const parts = [];
    for (;;) {
      const c = rest.indexOf(Q3);
      parts.push(c >= 0 ? rest.slice(0, c) : rest);
      if (c >= 0 || ++j >= lines.length) break;
      rest = lines[j];
    }
    // Prose only: lines indented past the docstring's own (an example's
    // commands or code) are left out.
    const ind = parts.slice(1).filter((l) => l.trim()).map(lead);
    const base = ind.length ? Math.min(...ind) : 0;
    const text = parts.map((l, k) => (k && l.trim() && lead(l) >= base + 4 ? "" : l.trim())).join("\\n").trim();
    return text ? { text, from: i + 1, to: j + 1 } : null;
  };
  // The docstring after the statement at line `at` (a def's signature, or
  // the pipeline's declaration), and the module's at the top of the file.
  const docAt = (lines, at) => {
    let depth = 0, i = at - 1;
    for (; i < lines.length && i < at + 11; i++) {
      for (const ch of lines[i].replace(/\\s#.*$/, "")) depth += "([{".includes(ch) ? 1 : ")]}".includes(ch) ? -1 : 0;
      if (depth <= 0) break;
    }
    for (i++; i < lines.length && !lines[i].trim(); i++);
    return docFrom(lines, i);
  };
  const moduleDoc = (lines) => {
    let i = 0;
    while (i < lines.length && (!lines[i].trim() || lines[i].trimStart().startsWith("#"))) i++;
    return docFrom(lines, i);
  };
  function place(a) {
    const r = a.getBoundingClientRect(), h = box.offsetHeight, w = box.offsetWidth;
    const below = r.bottom + 6 + h <= innerHeight || r.top < h + 6;
    box.style.top = (scrollY + (below ? r.bottom + 6 : r.top - h - 6)) + "px";
    box.style.left = (scrollX + Math.max(8, Math.min(r.left, innerWidth - w - 8))) + "px";
  }
  // A code link's line, or what a link elsewhere (a runs table's pipeline)
  // shows the code of (data-src).
  const srcOf = (a) => a.dataset.src || a.href;
  async function show(a) {
    clearTimeout(showT);
    const m = GH.exec(srcOf(a));
    if (!m) return;
    cur = a;
    const mine = ++shows;
    if (!box) {
      box = document.createElement("div");
      box.className = "peek";
      box.id = "peek";
      box.setAttribute("role", "tooltip");
      box.addEventListener("mouseenter", () => clearTimeout(hideT));
      box.addEventListener("mouseleave", () => hide(150));
      document.body.append(box);
    }
    const [, owner, repo, sha, path, line] = m;
    const at = Number(line);
    box.innerHTML = '<div class="peek__head">' + esc(path + ":" + at) + ' <span>at ' + esc(sha.slice(0, 7)) + "</span></div>" + '<div class="peek__body"><p class="peek__msg">Loading…</p></div>';
    box.hidden = false;
    a.setAttribute("aria-describedby", "peek");
    place(a);
    let body;
    try {
      const src = await load("https://github.com/" + owner + "/" + repo + "/blob/" + sha + "/" + path);
      const s = snippet(src.lines, at);
      // It opens with the docstring's first sentence, the rest under it,
      // the code without it; the pipeline's declaration, without one, with
      // its module's.
      const own = docAt(src.lines, at);
      const isDef = /^\\s*(def|fn)\\s/.test(src.lines[at - 1] || "");
      const doc = own || (isDef ? null : moduleDoc(src.lines));
      const [first, rest] = morcaLead(doc && doc.text);
      const out = own ? s.out.filter(([n]) => n < own.from || n > own.to) : s.out;
      body = (first ? '<p class="peek__lead">' + esc(first) + "</p>" : "") + (rest ? '<p class="peek__more">' + esc(rest) + "</p>" : "") +
        "<pre>" + out.map(([n, l]) => '<span class="peek__line' + (n === at ? " peek__line--at" : "") + '"><span class="peek__ln">' + n + "</span>" + (src.html[n - 1] ?? esc(l)) + "</span>").join("") + (s.more ? '<span class="peek__line"><span class="peek__ln"></span>…</span>' : "") + "</pre>";
    } catch (e) {
      body = '<p class="peek__msg">Can&#39;t load the source here (a private repository, or offline). The link opens it.</p>';
    }
    if (cur !== a || mine !== shows) return;
    box.querySelector(".peek__body").innerHTML = body;
    place(a);
  }
  function hide(after) {
    clearTimeout(showT);
    clearTimeout(hideT);
    hideT = setTimeout(() => {
      if (box) box.hidden = true;
      if (cur) cur.removeAttribute("aria-describedby");
      cur = null;
    }, after);
  }
  const link = (t) => { const a = t.closest && t.closest("a.src, a[data-src]"); return a && GH.test(srcOf(a)) ? a : null; };
  // A tap shows the code first, and a second tap follows the link. (The
  // tap's focus shows it before the click, so what counts is whether it
  // was shown when the finger came down.)
  let touch = false, shown = false;
  document.addEventListener("pointerdown", (e) => {
    touch = e.pointerType === "touch";
    const a = link(e.target);
    shown = !!(a && a === cur && box && !box.hidden);
    if (touch && cur && !a && !(box && box.contains(e.target))) hide(0);
  }, true);
  document.addEventListener("click", (e) => {
    const a = link(e.target);
    if (!a || !touch || shown) return;
    e.preventDefault();
    clearTimeout(hideT);
    if (a !== cur || !box || box.hidden) show(a);
  });
  // A live refresh that replaced the link shown: the box goes with it.
  document.addEventListener("morca:swap", () => { if (cur && !cur.isConnected) hide(0); });
  document.addEventListener("mouseover", (e) => {
    const a = link(e.target);
    if (!a) return;
    if (a.title) { a.dataset.title = a.title; a.removeAttribute("title"); }
    clearTimeout(hideT);
    if (a === cur) return;
    clearTimeout(showT);
    showT = setTimeout(() => show(a), 250);
  });
  document.addEventListener("mouseout", (e) => {
    const a = link(e.target);
    if (a && !a.contains(e.relatedTarget) && !(box && box.contains(e.relatedTarget))) hide(200);
  });
  document.addEventListener("focusin", (e) => {
    const a = link(e.target);
    if (a) { clearTimeout(hideT); show(a); }
    const h = e.target.closest && e.target.closest(".help");
    if (h) h.classList.remove("help--shut");
  });
  document.addEventListener("focusout", (e) => { if (link(e.target)) hide(0); });
  document.addEventListener("mouseover", (e) => {
    const h = e.target.closest && e.target.closest(".help");
    if (h && !h.contains(e.relatedTarget)) h.classList.remove("help--shut");
  });
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    if (cur) hide(0);
    for (const h of document.querySelectorAll(".help:hover, .help:focus-within")) h.classList.add("help--shut");
  });
})();
"""
"""Code on hover: a link to a line on GitHub (`a.src`), or a link with
one in its `data-src` (a runs table's pipeline), shows, after a moment, on
keyboard focus or on a first tap (a second follows the link), that
function's source, from its def through
its docstring, coloured, from `/code` (which fetches the file from
raw.githubusercontent.com and colours it, `morca._internal.highlight`) once per file; the
link itself is unchanged, so without scripts (or for a private repository)
it still opens the file. Escape closes it and any help shown."""


comptime USER_SLOT = "<!--morca-user-->"
"""Where `serve` puts who's logged in, or a link to log in."""


comptime _MARK = (
    '<svg class="top__mark" width="22" height="22" viewBox="0 0 16 16"'
    ' aria-hidden="true"><rect width="16" height="16" rx="3"'
    ' fill="var(--lake)"/><path d="M4.5 5L8 11.5M11.5 5L8 11.5"'
    ' stroke="var(--bg)" stroke-width="1.3"/><circle cx="4.5" cy="4.5" r="2"'
    ' fill="var(--bg)"/><circle cx="11.5" cy="4.5" r="2" fill="var(--bg)"/>'
    '<circle cx="8" cy="11.5" r="2" fill="var(--bg)"/></svg>'
)
"""morca's icon, the tab's three connected nodes, in the theme's colours."""


def _extra_links(mut h: Html):
    """The deployment's own nav links after Docs, from `MORCA_UI_LINKS`:
    `label=url` entries separated by commas, e.g. `Census ↗=https://...`.
    Entries without an http(s) url are left out."""
    for entry in comma_list(getenv("MORCA_UI_LINKS")):
        var eq = entry.find("=")
        if eq <= 0:
            continue
        var label = String(entry[byte=:eq].strip())
        var url = String(entry[byte = eq + 1 :].strip())
        if not label or not (
            url.startswith("https://") or url.startswith("http://")
        ):
            continue
        h.raw('<a href="')
        h.text(url)
        h.raw('" target="_blank" rel="noopener">')
        h.text(label)
        h.raw("</a>")


comptime _ICON = (
    '<link rel="icon" href="data:image/svg+xml,%3Csvg'
    " xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Crect"
    " width='16' height='16' rx='3' fill='%231d4ed8'/%3E%3Cpath d='M4.5 5L8"
    " 11.5M11.5 5L8 11.5' stroke='%23fff' stroke-width='1.3'/%3E%3Ccircle"
    " cx='4.5' cy='4.5' r='2' fill='%23fff'/%3E%3Ccircle cx='11.5' cy='4.5'"
    " r='2' fill='%23fff'/%3E%3Ccircle cx='8' cy='11.5' r='2'"
    " fill='%23fff'/%3E%3C/svg%3E\">"
)
"""A blue DAG of three nodes as the tab icon, so morca's tab stands apart
from the census's amber bar chart."""


def posthog_host(v: String) -> String:
    """`MORCA_POSTHOG_HOST` as the snippet's host: a path on the UI's own
    origin (`/ph`, a first-party proxy) or an `https://` origin, with no
    trailing `/`; PostHog's own (US) when it's empty; empty when it's
    neither, which leaves the snippet out."""
    if not v:
        return "https://us.i.posthog.com"
    var t = String(v.rstrip("/"))
    var rest = t
    if t.startswith("https://"):
        rest = String(t[byte=8:])
    elif not t.startswith("/") or t.byte_length() < 2:
        return ""
    for byte in rest.as_bytes():
        var b = Int(byte)
        if not (
            (b >= ord("a") and b <= ord("z"))
            or (b >= ord("A") and b <= ord("Z"))
            or (b >= ord("0") and b <= ord("9"))
            or b == ord("/")
            or b == ord("_")
            or b == ord("-")
            or b == ord(".")
            or b == ord(":")
        ):
            return ""
    return t


def _posthog(mut h: Html):
    """PostHog product analytics in the page head when `MORCA_POSTHOG_KEY` is
    a project key (`phc_` and letters, digits, `_` or `-`), nothing otherwise.

    `array.js` and the events go to `MORCA_POSTHOG_HOST` (`posthog_host`):
    PostHog's own when it isn't set, or a first-party proxy such as `/ph` on
    the UI's own origin (the mojourney-ph Worker in magmalake/magmalake.org,
    which the UI itself doesn't serve), so ad-blockers keep it.
    `persistence: 'memory'` sets no cookie and writes no `localStorage`, so
    there is nothing to consent to. `site: "morca"` tells its events apart
    in a shared PostHog project.
    """
    var key = getenv("MORCA_POSTHOG_KEY")
    if not key.startswith("phc_"):
        return
    for byte in key.as_bytes():
        var b = Int(byte)
        if not (
            (b >= ord("a") and b <= ord("z"))
            or (b >= ord("A") and b <= ord("Z"))
            or (b >= ord("0") and b <= ord("9"))
            or b == ord("_")
            or b == ord("-")
        ):
            return
    var host = posthog_host(getenv("MORCA_POSTHOG_HOST"))
    if not host:
        return
    # PostHog's own host serves array.js from its assets host.
    var script = String(host, "/static/array.js")
    var api = String("'", host, "'")
    if host.startswith("/"):
        api = String("location.origin+'", host, "'")
    elif host == "https://us.i.posthog.com":
        script = "https://us-assets.i.posthog.com/static/array.js"
    h.raw(
        '<script defer src="',
        script,
        '"></script>',
        '<script>window.addEventListener("DOMContentLoaded",function(){',
        'if(window.posthog){posthog.init("',
        key,
        '",{api_host:',
        api,
        ",",
        "ui_host:'https://us.posthog.com',defaults:'2025-05-24',",
        "persistence:'memory',capture_exceptions:true});",
        "posthog.register({site:'morca'});}});</script>",
    )


def page_html(title: String, active: StaticString, body: Html) -> String:
    var h = Html()
    h.raw(
        '<!doctype html><html lang="en"><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        _ICON,
        "<title>",
    )
    h.text(title, " · morca")
    h.raw(
        '</title><link rel="stylesheet" href="/static/morca.css">',
    )
    _posthog(h)
    h.raw(
        "</head>",
        '<body class="',
        AUTH_SLOT,
        '">',
        '<header class="top"><a class="top__brand" href="/">',
        _MARK,
        "morca</a><nav>",
    )
    for item in [
        ("/", "Pipelines"),
        ("/runs", "Runs"),
        ("/datasets", "Datasets"),
    ]:
        h.raw('<a href="', item[0], '"')
        if item[0] == active:
            h.raw(' aria-current="page"')
        h.raw(">", item[1], "</a>")
    # Ops: a link to Alerts, with Alerts, Control, Pools and Watchdog under
    # it. The menu is plain links, shown by CSS (hover, keyboard focus)
    # and, on a phone, always, so it needs no JavaScript.
    h.raw('<div class="menu"><a href="/ops"')
    if active.startswith("/ops/") or active == "/watchdog":
        h.raw(' aria-current="page"')
    h.raw(' aria-haspopup="true">Ops</a><div class="menu__sub">')
    for item in [
        ("/ops/alerts", "Alerts"),
        ("/ops/control", "Control"),
        ("/ops/pools", "Pools"),
        ("/watchdog", "Watchdog"),
    ]:
        h.raw('<a href="', item[0], '"')
        if item[0] == active:
            h.raw(' aria-current="page"')
        h.raw(">", item[1], "</a>")
    h.raw("</div></div>")
    h.raw('<a href="')
    h.text(getenv("MORCA_DOCS_URL", "https://mlake.dev/s/orca/docs/"))
    h.raw('" target="_blank" rel="noopener">Docs</a>')
    _extra_links(h)
    h.raw("</nav>", USER_SLOT, "</header><main>")
    h.raw(body.out)
    h.raw(
        "</main>",
        ASK_DIALOG,
        "<script>",
        _POLL,
        "</script><script>",
        _ASK,
        "</script><script>",
        _CMD,
        "</script><script>",
        LEAD_JS,
        "</script><script>",
        _TABS,
        "</script><script>",
        _TIPS,
        "</script><script>",
        _PEEK,
        "</script><script>",
        STEP_CARDS_JS,
        "</script><script>",
        LOADING_JS,
        "</script></body></html>",
    )
    return h^.finish()


comptime AUTH_SLOT = "morca-auth"
"""The `<body>`'s class until the page is answered: `anon` when login is on
and no one is logged in, which hides the inline action buttons and shows
their "Log in to ..." links instead."""


comptime HERE_SLOT = "__morca_here__"
"""Where a "Log in to ..." link comes back to: the page's own path and
query, encoded, filled in when the page is answered."""


def act_button(
    mut h: Html,
    action: String,
    label: StaticString,
    verb: StaticString,
    cli: String,
    danger: Bool = False,
    step: String = "",
    ask: String = "",
    tell: String = "",
    yes: String = "",
    no: String = "",
    harm: Bool = True,
    partitions: String = "",
):
    """A small form posting to `action`, beside the status it changes: a
    button labelled `label` whose title is the command line that does the
    same, with "Log in to `verb`" in its place while login is needed. A
    `danger` one (red), or one with a question `ask`, asks first where
    there's JavaScript (`ask_attrs`): `ask`, or "`label`?", with `tell`
    saying what will happen and `yes`/`no` on the buttons; yes is red
    unless `harm` is false. `step` and `partitions`, if given, are posted
    as those fields."""
    h.raw('<form class="act" method="post" action="')
    h.text(action)
    h.raw('"')
    if danger or ask:
        ask_attrs(h, ask if ask else String(label, "?"), tell, yes, no, harm)
    h.raw(">")
    if step:
        h.raw('<input type="hidden" name="step" value="')
        h.text(step)
        h.raw('">')
    if partitions:
        h.raw('<input type="hidden" name="partitions" value="')
        h.text(partitions)
        h.raw('">')
    h.raw('<button type="submit" class="act__btn', " danger" if danger else "")
    h.raw('" title="')
    h.text(cli)
    h.raw(
        '">', label, '</button></form><a class="act__login" href="/login?next='
    )
    h.raw(HERE_SLOT, '" title="')
    h.text(cli)
    h.raw('">Log in to ', verb, "</a>")


def help_tip(
    mut h: Html,
    id: String,
    key: String,
    text: StaticString,
    docs: StaticString = "",
):
    """A "?" after a fact's name (`Html.help`)."""
    h.help(id, key, text, docs)


def _strip_tags(s: StringSlice) -> String:
    """`s`'s text: its tags dropped, and a sort arrow (▲ ▼)."""
    var out = String()
    var inside = False
    for cp in s.codepoint_slices():
        if cp == "<":
            inside = True
        elif cp == ">":
            inside = False
        elif not inside:
            out.write(cp)
    return String(out.replace("▲", "").replace("▼", "").strip())


def with_header_help(html: String, prefix: String) -> String:
    """`html` with a "?" in every table header `morca._internal.ui.terms` has help for,
    by its text (and the table its `data-help` names), as `help_tip` writes
    one; ids `help-<prefix>-<n>`. One pass over the page, so every table,
    whoever wrote it, gets them."""
    var out = String()
    var at = 0
    var n = 0
    while True:
        var open = html.find("<th", at)
        if open < 0:
            break
        var gt = html.find(">", open)
        var close = html.find("</th>", open)
        if gt < 0 or close < 0 or gt > close:
            break
        # Only <th> and <th ...>, not <thead>.
        var next = String(html[byte = open + 3 : open + 4])
        if next != ">" and next != " ":
            out.write(html[byte = at : open + 3])
            at = open + 3
            continue
        var tag = String(html[byte=open:gt])
        var inner = String(html[byte = gt + 1 : close])
        var table = String()
        var dh = tag.find('data-help="')
        if dh >= 0:
            var q = tag.find('"', dh + 11)
            table = String(tag[byte = dh + 11 : q])
        var label = _strip_tags(inner)
        var text = header_help(label, table)
        out.write(html[byte=at:close])
        if text and 'class="help"' not in inner:
            var h = Html()
            help_tip(h, String(prefix, "-", n), label, text)
            out.write(h^.finish())
            n += 1
        at = close
    out.write(html[byte=at:])
    return out^


def fact_term(
    mut h: Html,
    key: StaticString,
    id: StaticString,
    help: StaticString,
    docs: StaticString = "",
):
    """A fact's `<dt>`: its name with its help."""
    h.raw("<dt>", key)
    help_tip(h, id, key, help, docs)
    h.raw("</dt>")


def fact_item(
    mut h: Html,
    key: StaticString,
    id: StaticString,
    help: StaticString,
    docs: StaticString = "",
):
    """A fact's `<dt>`, its name with its help, then its `<dd>` opened."""
    fact_term(h, key, id, help, docs)
    h.raw("<dd>")


comptime LIVE_EVERY = 5
"""Seconds between refreshes of a list with a run going on."""


comptime IDLE_EVERY = 30
"""Seconds between refreshes of a list's newest page with nothing going on:
slow, only to show the runs a schedule or sensor starts."""


def card_open(
    mut h: Html,
    id: StaticString,
    title: StaticString,
    help: StaticString,
    docs: StaticString = "",
    facts: Bool = True,
):
    """A run page's card opened: its anchor `id`, then its heading with a
    "?" (`help`, its id `card-<id>`), closed. The caller ends the
    `<section>`."""
    h.raw(
        '<section class="card',
        " card--facts" if facts else "",
        '" id="',
        id,
        '"><h2>',
        title,
    )
    help_tip(h, String("card-", id), title, help, docs)
    h.raw("</h2>")
