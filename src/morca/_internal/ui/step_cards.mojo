"""A card per step, on hover, keyboard focus or a tap, in the UI's steps
views: a pipeline's Steps card (Graph and Table) and a run's (Table,
Timeline and Graph).

What a card shows is in the page, so a hover asks nothing of the server: a
`<script type="application/json" class="step-cards">` in the Steps card
holds each step's `StepCard` (its kind, `after=`, function signature,
types, the datasets it reads and writes, where its code is, and on a
pipeline's page what its latest runs took and used) and, on a run's page,
each attempt's `AttemptCard`. An element with `data-step` (and on a run's
page `data-attempt`) shows the card of that step (and attempt), drawn by
`STEP_CARDS_JS`. The one thing fetched is the function's own signature and
docstring, from the source at the commit (`/code?u=&at=`, `def_summary`),
once per step per page; until it comes, or where the code can't be had, the
signature is the one `describe` records, its argument names morca's.
"""

from morca._internal.highlight import highlight
from morca._internal.json import quote


def _lower(b: UInt8) -> Bool:
    return b >= UInt8(ord("a")) and b <= UInt8(ord("z"))


def _ident(b: UInt8) -> Bool:
    return (
        _lower(b)
        or (b >= UInt8(ord("A")) and b <= UInt8(ord("Z")))
        or (b >= UInt8(ord("0")) and b <= UInt8(ord("9")))
        or b == UInt8(ord("_"))
    )


def _dtype_name(d: String) -> String:
    """A `DType`'s scalar's name: `int` -> `Int`, `uint8` -> `UInt8`,
    `float64` -> `Float64`, `bfloat16` -> `BFloat16`."""
    for p in [("uint", "UInt"), ("bfloat", "BFloat")]:
        if d.startswith(p[0]):
            return String(p[1], d[byte = String(p[0]).byte_length() :])
    if not d:
        return d
    return String(String(d[byte=0]).upper(), d[byte=1:])


def short_type(name: StringSpan) -> String:
    """A type's name as its code writes it: modules dropped (`morca.month.
    Month` -> `Month`, `dista.seq.Seq[toy.Measured]` -> `Seq[Measured]`,
    a `::` path too), and a scalar `SIMD[DType.int, 1]` -> `Int`."""
    var s = String(name).replace("::", ".")
    var out = String()
    var b = s.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        if not _ident(b[i]):
            out.write(String(s[byte = i : i + 1]))
            i += 1
            continue
        # A dotted run: drop each leading segment that's a module (lower
        # case), keep the rest (`DType.int`).
        var j = i
        var keep = i
        while j < n and (_ident(b[j]) or b[j] == UInt8(ord("."))):
            if b[j] == UInt8(ord(".")) and _lower(b[keep]):
                keep = j + 1
            j += 1
        out.write(String(s[byte=keep:j]))
        i = j
    # Scalars, as `Int` and `Float64` are.
    while True:
        var at = out.find("SIMD[DType.").or_else(-1)
        if at < 0:
            break
        var head = at + 11
        var comma = out.find(", 1]", head).or_else(-1)
        if comma < 0:
            break
        var next = String(
            out[byte=:at],
            _dtype_name(String(out[byte=head:comma])),
            out[byte = comma + 4 :],
        )
        out = next^
    return out^


def function_name(function: StringSpan) -> String:
    """`toy::days(morca::ctx::Ctx,...)` -> `days`."""
    var f = String(function)
    var paren = f.find("(").or_else(-1)
    if paren >= 0:
        var head = String(f[byte=:paren])
        f = head^
    var at = f.rfind("::").or_else(-1)
    return String(f[byte = at + 2 :]) if at >= 0 else f


def signature(
    function: StringSpan, input: StringSpan, output: StringSpan
) -> String:
    """The step function's signature from what `describe` records:
    `def days(mut ctx: Ctx, input: Month) raises -> Measured`. Its
    argument names are morca's, as `describe` has none."""
    return String(
        "def ",
        function_name(function),
        "(mut ctx: Ctx, input: ",
        short_type(input),
        ") raises -> ",
        short_type(output),
    )


def signature_html(sig: StringSpan) -> String:
    """`sig`, coloured (`morca._internal.highlight`)."""
    var lines = highlight(sig)
    var out = String()
    for i in range(len(lines)):
        out.write("\n" if i else "", lines[i])
    return out^


@fieldwise_init
struct DefSummary(Copyable, Movable):
    """A function's signature, the 1-based lines `start` through `end`
    (0 for none found), and its docstring's first paragraph."""

    var start: Int
    var end: Int
    var doc: String


comptime _SIG_LINES = 12
"""The most lines a signature is taken to have."""


def _strip(s: StringSpan) -> String:
    return String(String(s).strip())


def def_summary(text: StringSpan, line: Int) -> DefSummary:
    """The signature of the `def` at `line` of `text` (through the line
    that closes its brackets and ends with `:`) and its docstring's first
    paragraph, joined onto one line; the start 0 if `line` isn't a `def`."""
    var lines = List[String]()
    for l in String(text).split("\n"):
        lines.append(String(l))
    if line < 1 or line > len(lines):
        return DefSummary(0, 0, "")
    var first = _strip(lines[line - 1])
    if not (first.startswith("def ") or first.startswith("fn ")):
        return DefSummary(0, 0, "")
    var depth = 0
    var end = 0
    var i = line - 1
    while i < len(lines) and i < line - 1 + _SIG_LINES:
        for b in lines[i].as_bytes():
            if b == UInt8(ord("(")) or b == UInt8(ord("[")):
                depth += 1
            elif b == UInt8(ord(")")) or b == UInt8(ord("]")):
                depth -= 1
        var t = _strip(lines[i])
        var hash = t.find("  #").or_else(-1)
        if hash >= 0:
            var code = _strip(t[byte=:hash])
            t = code^
        if depth <= 0 and t.endswith(":"):
            end = i + 1
            break
        i += 1
    if end == 0:
        return DefSummary(0, 0, "")
    # The docstring: the first line after the signature, if it opens one.
    var j = end
    while j < len(lines) and not _strip(lines[j]):
        j += 1
    if j >= len(lines):
        return DefSummary(line, end, "")
    var open = _strip(lines[j])
    var q = String('"""')
    if open.startswith("r"):
        var unraw = String(open[byte=1:])
        open = unraw^
    if not open.startswith(q):
        return DefSummary(line, end, "")
    var doc = String()
    var rest = String(open[byte=3:])
    while True:
        var close = rest.find(q).or_else(-1)
        var part = _strip(rest[byte=:close]) if close >= 0 else _strip(rest)
        if not part and doc:
            break  # a blank line ends the first paragraph
        if part:
            doc.write(" " if doc else "", part)
        if close >= 0:
            break
        j += 1
        if j >= len(lines):
            break
        rest = lines[j]
    return DefSummary(line, end, doc^)


def first_line(s: StringSpan) -> String:
    """`s` up to its first line break, trimmed."""
    var t = _strip(s)
    var nl = t.find("\n").or_else(-1)
    return _strip(t[byte=:nl]) if nl >= 0 else t^


def duration_text(seconds: Float64) -> String:
    """A duration as `<1s`, `42s`, `3m 07s` or `2h 05m`; empty for a
    negative one."""
    if seconds < 0:
        return String()
    if seconds < 1:
        return "<1s"
    var s = Int(seconds + 0.5)
    if s < 60:
        return String(s, "s")
    if s < 3600:
        return String(s // 60, "m ", _two(s % 60), "s")
    return String(s // 3600, "h ", _two(s % 3600 // 60), "m")


def _two(n: Int) -> String:
    return String("0", n) if n < 10 else String(n)


def _strings(mut out: String, names: List[String]):
    out.write("[")
    for i in range(len(names)):
        out.write(", " if i else "", quote(names[i]))
    out.write("]")


@fieldwise_init
struct StepCard(Copyable, Movable):
    """What a step's card shows: the step as registered, and on a
    pipeline's page what its latest runs did (`recent_runs` 0 for none)."""

    var name: String
    var kind: String
    var kind_help: String
    var after: String
    var function: String
    var input: String
    var output: String
    var reads: List[String]
    var writes: List[String]
    var src: String
    """A link to its `def` line on the code's host, or empty."""
    var at: String
    """Where that is, `file.mojo:26`."""
    var commit: String
    var recent_runs: Int
    var recent_attempts: Int
    var recent_failed: Int
    var took: String
    """Its succeeded attempts' p50 and max, as text, or empty."""
    var peak: String
    """Its attempts' peak memory's p50 and max, as text, or empty."""

    def json(self) -> String:
        var sig = signature(self.function, self.input, self.output)
        var out = String("{")
        out.write('"kind": ', quote(self.kind))
        out.write(', "kind_help": ', quote(self.kind_help))
        out.write(', "after": ', quote(self.after))
        out.write(', "sig": ', quote(signature_html(sig)))
        out.write(', "input": ', quote(short_type(self.input)))
        out.write(', "output": ', quote(short_type(self.output)))
        out.write(', "reads": ')
        _strings(out, self.reads)
        out.write(', "writes": ')
        _strings(out, self.writes)
        out.write(', "src": ', quote(self.src))
        out.write(', "at": ', quote(self.at))
        out.write(
            ', "commit": ',
            quote(
                String(self.commit[byte = : min(7, self.commit.byte_length())])
            ),
        )
        if self.recent_runs > 0:
            out.write(', "recent": {"runs": ', self.recent_runs)
            out.write(', "attempts": ', self.recent_attempts)
            out.write(', "failed": ', self.recent_failed)
            out.write(', "took": ', quote(self.took))
            out.write(', "peak": ', quote(self.peak), "}")
        out.write("}")
        return out^


@fieldwise_init
struct AttemptCard(Copyable, Movable):
    """What an attempt adds to its step's card on a run's page; usage
    values are text, empty where it wasn't measured."""

    var id: Int
    var step: String
    var partition: String
    var attempt: Int
    var status: String
    var status_help: String
    var started: String
    var ended: String
    var took: String
    var peak: String
    var cpu: String
    var cores: String
    var error: String
    """Its error's first line."""
    var href: String
    """Its page."""

    def json(self) -> String:
        var out = String("{")
        out.write('"step": ', quote(self.step))
        out.write(', "partition": ', quote(self.partition))
        out.write(', "attempt": ', self.attempt)
        out.write(', "status": ', quote(self.status))
        out.write(', "status_help": ', quote(self.status_help))
        out.write(', "started": ', quote(self.started))
        out.write(', "ended": ', quote(self.ended))
        out.write(', "took": ', quote(self.took))
        out.write(', "peak": ', quote(self.peak))
        out.write(', "cpu": ', quote(self.cpu))
        out.write(', "cores": ', quote(self.cores))
        out.write(', "error": ', quote(first_line(self.error)))
        out.write(', "href": ', quote(self.href), "}")
        return out^


def cards_script(steps: List[StepCard], attempts: List[AttemptCard]) -> String:
    """The page's cards, as JSON in a `<script type="application/json">`
    (`<` written `\\u003c`, so nothing in it ends the script)."""
    var out = String('{"steps": {')
    for i in range(len(steps)):
        out.write(
            ", " if i else "", quote(steps[i].name), ": ", steps[i].json()
        )
    out.write('}, "attempts": {')
    for i in range(len(attempts)):
        out.write(", " if i else "", '"', attempts[i].id, '": ')
        out.write(attempts[i].json())
    out.write("}}")
    return String(
        '<script type="application/json" class="step-cards">',
        out.replace("<", "\\u003c"),
        "</script>",
    )


def def_json(text: StringSpan, line: Int) -> String:
    """`/code?u=&at=`'s answer: the signature at `line` of `text`, its
    lines coloured, and its docstring's first paragraph:
    `{"line": 26, "sig": ["<span ...>def</span> ..."], "doc": "..."}`;
    `sig` is empty if `line` isn't a `def`."""
    var d = def_summary(text, line)
    var out = String('{"line": ', line, ', "sig": [')
    if d.start > 0:
        var lines = highlight(text)
        for i in range(d.start - 1, min(d.end, len(lines))):
            out.write(", " if i > d.start - 1 else "", quote(lines[i]))
    out.write('], "doc": ', quote(d.doc), "}")
    return out^


comptime LEAD_JS = """
function morcaLead(doc) {
  const t = String(doc || "").trim();
  if (!t) return ["", ""];
  const para = t.split(/\\n\\s*\\n/)[0], m = /[.](\\s|$)/.exec(para);
  const end = m ? m.index + 1 : para.length;
  let first = para.slice(0, end).replace(/\\s+/g, " ").trim();
  if (first.length > 160) first = first.slice(0, 159).trimEnd() + "…";
  return [first, t.slice(end).replace(/\\s+/g, " ").trim()];
}
"""
"""A docstring's lead (`morcaLead`), which every code hover card opens
with: its first sentence (to the first ". " or blank line), on one line,
at most 160 characters with an ellipsis; and the rest, on one line too."""


comptime STEP_CARDS_JS = """
(() => {
  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  const parsed = new WeakMap(), code = new Map();
  let box = null, cur = null, showT = 0, hideT = 0, touch = false;
  // The cards of the Steps card `el` is in, or the page's first.
  const data = (el) => {
    const sec = el.closest("[data-step-cards]");
    const s = (sec && sec.querySelector("script.step-cards")) || document.querySelector("script.step-cards");
    if (!s) return null;
    if (!parsed.has(s)) { try { parsed.set(s, JSON.parse(s.textContent)); } catch (e) { parsed.set(s, null); } }
    return parsed.get(s);
  };
  const of = (t) => {
    if (!t || !t.closest) return null;
    const el = t.closest("[data-step]");
    if (el) return el;
    return t.matches && t.matches("a") ? t.querySelector(":scope > [data-step]") : null;
  };
  // A dataset's data link is private if the page's own link to it is
  // (the Datasets line has them all), so the stylesheet hides it alike.
  const priv = (href) => !!document.querySelector('a.data-link--private[href="' + href + '"]');
  const datasets = (names) => names.length ? names.map((n) => {
    const data = "/datasets/" + encodeURIComponent(n) + "?tab=data";
    return '<a href="/datasets/' + encodeURIComponent(n) + '">' + esc(n) + '</a> <a class="data-link' + (priv(data) ? " data-link--private" : "") + '" href="' + esc(data) + '">data</a>';
  }).join(", ") : '<span class="muted">none</span>';
  const fact = (k, v) => v ? "<dt>" + k + "</dt><dd>" + v + "</dd>" : "";
  function render(el, d) {
    const s = d.steps[el.dataset.step];
    if (!s) return null;
    const a = el.dataset.attempt ? d.attempts[el.dataset.attempt] : null;
    let h = '<div class="scard__head"><strong>' + esc(el.dataset.step) + "</strong> " +
      (s.kind_help ? '<span class="term" data-tip="' + esc(s.kind_help) + '">' + esc(s.kind) + "</span>" : esc(s.kind)) +
      (s.after ? ' <span class="muted">after</span> <code>' + esc(s.after) + "</code>" : "") + "</div>";
    if (s.src) h += '<p class="scard__lead muted">Loading its docstring…</p>';
    h += '<pre class="scard__sig"><code>' + s.sig + "</code></pre>";
    if (s.src) h += '<p class="scard__doc muted"></p><p class="scard__src"><a href="' + esc(s.src) + '" target="_blank" rel="noopener" title="View source on GitHub at ' + esc(s.commit) + '">' + esc(s.at) + " at " + esc(s.commit) + " ↗</a></p>";
    h += '<dl class="scard__facts">' + fact("In", "<code>" + esc(s.input) + "</code>") + fact("Out", "<code>" + esc(s.output) + "</code>") +
      fact("Reads", datasets(s.reads)) + fact("Writes", datasets(s.writes));
    if (a) {
      h += fact("Attempt", '<a href="' + esc(a.href) + '">' + esc(a.attempt) + "</a>" + (a.partition ? " of " + esc(a.partition) : "") + ' <span class="status status--' + esc(a.status.replace(/ /g, "-")) + '">' + esc(a.status) + "</span>") +
        fact("Started", esc(a.started)) + fact("Ended", esc(a.ended)) + fact("Took", esc(a.took)) +
        fact("Peak", esc(a.peak)) + fact("CPU", esc(a.cpu) + (a.cores ? " on up to " + esc(a.cores) + " cores" : "")) +
        fact("Error", a.error ? '<span class="error">' + esc(a.error) + "</span>" : "");
    } else if (s.recent) {
      const r = s.recent;
      h += fact("Last " + r.runs + (r.runs === 1 ? " run" : " runs"), esc(r.attempts + (r.attempts === 1 ? " attempt" : " attempts")) + (r.failed ? ', <span class="error">' + esc(r.failed) + " failed</span>" : ", none failed")) +
        fact("Took", esc(r.took)) + fact("Peak", esc(r.peak));
    } else if (!el.dataset.attempt && d.attempts && !Object.keys(d.attempts).length) {
      h += fact("Runs", '<span class="muted">none yet</span>');
    }
    return { html: h + "</dl>", src: s.src };
  }
  // The function's own signature and docstring, from its code (`/code`).
  const load = (src) => {
    if (!code.has(src)) {
      const m = /^(.*)#L([0-9]+)$/.exec(src);
      code.set(src, m ? fetch("/code?u=" + encodeURIComponent(m[1]) + "&at=" + m[2]).then((r) => { if (!r.ok) throw new Error(r.status); return r.json(); }) : Promise.reject(new Error("no line")));
    }
    return code.get(src);
  };
  function place(el) {
    const r = el.getBoundingClientRect(), w = box.offsetWidth, h = box.offsetHeight;
    const below = r.bottom + 6 + h <= innerHeight || r.top < h + 6;
    box.style.top = Math.max(8, below ? r.bottom + 6 : r.top - h - 6) + "px";
    box.style.left = Math.max(8, Math.min(r.left, innerWidth - w - 8)) + "px";
  }
  async function show(el) {
    const d = data(el);
    const c = d && render(el, d);
    if (!c) return;
    if (!box) {
      box = document.createElement("div");
      box.className = "scard";
      box.id = "scard";
      box.setAttribute("role", "tooltip");
      box.addEventListener("mouseenter", () => clearTimeout(hideT));
      box.addEventListener("mouseleave", () => hide(150));
      document.body.append(box);
    }
    // Its own title would show over the card.
    for (const t of el.querySelectorAll("title")) { el.dataset.title = t.textContent; t.remove(); }
    cur = el;
    box.innerHTML = c.html;
    box.hidden = false;
    el.setAttribute("aria-describedby", "scard");
    place(el);
    if (!c.src) return;
    let sig = null, doc = "";
    try {
      const got = await load(c.src);
      if (got.sig && got.sig.length) sig = got.sig.join("\\n");
      doc = got.doc || "";
    } catch (e) {}
    if (cur !== el) return;
    if (sig) box.querySelector(".scard__sig code").innerHTML = sig;
    const [first, rest] = morcaLead(doc);
    const l = box.querySelector(".scard__lead"), p = box.querySelector(".scard__doc");
    if (l) { if (first) { l.textContent = first; l.classList.remove("muted"); } else l.remove(); }
    if (p) { if (rest) p.textContent = rest; else p.remove(); }
    place(el);
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
  const inBox = (t) => box && t && box.contains(t);
  document.addEventListener("mouseover", (e) => {
    const el = of(e.target);
    if (!el || touch) return;
    clearTimeout(hideT);
    if (el === cur) return;
    clearTimeout(showT);
    showT = setTimeout(() => show(el), 200);
  });
  document.addEventListener("mouseout", (e) => {
    const el = of(e.target);
    if (el && !el.contains(e.relatedTarget) && !inBox(e.relatedTarget)) hide(200);
  });
  document.addEventListener("focusin", (e) => {
    const el = of(e.target);
    if (el) { clearTimeout(hideT); clearTimeout(showT); if (el !== cur) show(el); }
  });
  document.addEventListener("focusout", (e) => { if (of(e.target) && !inBox(e.relatedTarget)) hide(150); });
  // A tap shows the card; on a box that links to its code, the first tap
  // shows it and the next follows the link.
  document.addEventListener("pointerdown", (e) => {
    touch = e.pointerType === "touch";
    if (!of(e.target) && !inBox(e.target) && cur) hide(0);
  }, true);
  document.addEventListener("click", (e) => {
    const el = of(e.target);
    if (!el || !touch) return;
    if (el !== cur || (box && box.hidden)) { e.preventDefault(); clearTimeout(hideT); show(el); }
  });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape" && cur) hide(0); });
  // A scroll (focus can scroll a table or the timeline) moves the card with
  // its step, and closes it once the step is out of sight.
  addEventListener("scroll", (e) => {
    if (!cur || !box || box.hidden || inBox(e.target)) return;
    const r = cur.getBoundingClientRect();
    if (r.bottom < 0 || r.top > innerHeight || r.right < 0 || r.left > innerWidth) hide(0);
    else place(cur);
  }, true);
})();
"""
"""The step cards (`[data-step]`, with `data-attempt` on a run's page): the
card drawn from the page's `script.step-cards` after a moment's hover, on
keyboard focus or on a tap, beside the element (above it where there's no
room), kept while the pointer is over it, moved with it on a scroll, and
closed by Escape, a tap elsewhere or its step scrolling out of sight. The function's own signature and docstring are fetched
once per step (`/code?u=&at=`); without them the card keeps the recorded
signature, and without scripts the page is as it was."""
