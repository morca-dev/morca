"""Start runs, on a pipeline's Operate tab: the form, its date picker
(`morca._internal.ui.coverage`), and the preview of what it would queue
(`morca._internal.views.start`), updated as you type.
"""

from morca._internal.html import Html, url_encode
from morca._internal.ui.layout import cmd_box, docs_link
from morca._internal.views.commands import backfill_cmd, remote_cmd, shell_quote
from morca._internal.db.pipelines_view import PipelineRow
from morca._internal.views.start import (
    StartPreview,
    one_run_line,
    preview_line,
    unit_word,
)
from morca._internal.timekeys import example_of


comptime _CAL_SCRIPT = """
(() => {
  const root = document.querySelector("[data-calendar]");
  const f = document.getElementById("start");
  if (!root || !f) return;
  const field = f.elements.partitions;
  const words = { done: "done", failed: "failed", live: "running or queued", open: "not done", outside: "outside the pipeline's range" };
  const names = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];
  const two = (n) => String(n).padStart(2, "0");
  const cache = {};
  let data = null, focus = "", anchor = "", base = "", mine = false;
  const el = (tag, cls, text) => {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined) e.textContent = text;
    return e;
  };
  const ranges = () => field.value.split(",").map((s) => s.trim()).filter(Boolean).map((s) => {
    const p = s.split("..");
    return [p[0], p[1] || p[0]];
  });
  const marks = () => {
    const rs = ranges();
    for (const b of root.querySelectorAll("button.cal__day")) {
      const k = b.dataset.key;
      const on = rs.some((r) => k >= r[0] && k <= r[1]);
      b.classList.toggle("cal--sel", on);
      b.setAttribute("aria-pressed", on ? "true" : "false");
      b.classList.toggle("cal--anchor", k === anchor);
    }
    const hint = root.querySelector(".cal__hint");
    if (hint) hint.textContent = anchor ? "Now pick the last " + data.unit + " (the same one again for just that one)." : "Pick the first " + data.unit + ", then the last. Hold ctrl or cmd to add another range.";
  };
  const render = () => {
    root.replaceChildren();
    const daily = data.unit === "day";
    const title = daily ? names[+data.period.slice(5, 7) - 1] + " " + data.period.slice(0, 4) : data.period;
    const head = el("div", "cal__head");
    const nav = (to, label, glyph) => {
      const b = el("button", "", glyph);
      b.type = "button";
      b.setAttribute("aria-label", label);
      b.disabled = !to;
      b.addEventListener("click", () => load(to));
      return b;
    };
    const t = el("strong", "", title);
    t.setAttribute("aria-live", "polite");
    head.append(nav(data.prev, "Previous " + data.unit + (daily ? " month" : " year"), "‹"), t, nav(data.next, "Next " + (daily ? "month" : "year"), "›"));
    const grid = el("div", "cal__grid " + (daily ? "cal__grid--days" : "cal__grid--months"));
    grid.setAttribute("role", "group");
    grid.setAttribute("aria-label", title);
    if (daily) {
      for (const w of ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]) grid.append(el("span", "cal__dow", w));
      for (let i = 0; i < data.weekday; i++) grid.append(el("span", "cal__pad"));
    }
    const keys = data.cells.map((c) => c.key);
    if (!keys.includes(focus)) {
      const sel = ranges().map((r) => r[0]).find((k) => keys.includes(k));
      focus = sel || (keys.includes(data.today) ? data.today : (data.cells.find((c) => c.state !== "outside") || data.cells[0]).key);
    }
    data.cells.forEach((c, i) => {
      const b = el("button", "cal__day cal--" + c.state, daily ? String(i + 1) : names[i].slice(0, 3));
      b.type = "button";
      b.dataset.key = c.key;
      b.setAttribute("aria-label", c.key + ": " + words[c.state]);
      b.tabIndex = c.key === focus ? 0 : -1;
      if (c.state === "outside") b.setAttribute("aria-disabled", "true");
      grid.append(b);
    });
    const legend = el("p", "muted cal__legend");
    for (const s of ["done", "failed", "live", "open", "outside"]) {
      legend.append(el("span", "cal__key cal--" + s), " " + data.counts[s] + " " + words[s] + " ");
    }
    const hint = el("p", "muted cal__hint");
    hint.setAttribute("aria-live", "polite");
    root.append(head, grid, legend, hint);
    marks();
  };
  const load = async (period, then) => {
    try {
      if (!cache[period || ""]) {
        const r = await fetch(root.dataset.calendar + (period ? "?month=" + encodeURIComponent(period) : ""));
        if (!r.ok) throw new Error(r.status);
        cache[period || ""] = await r.json();
      }
      data = cache[period || ""];
      if (then) focus = then;
      render();
      if (then) root.querySelector('button[data-key="' + then + '"]').focus();
    } catch (e) {
      if (period) return load("");
      root.replaceChildren(el("p", "muted", "The calendar couldn't be loaded; type the range instead."));
    }
  };
  const pick = (b, e) => {
    if (b.getAttribute("aria-disabled")) return;
    const k = b.dataset.key;
    focus = k;
    if (!anchor) {
      base = (e.ctrlKey || e.metaKey) && field.value.trim() ? field.value.trim() + "," : "";
      anchor = k;
      field.value = base + k;
    } else {
      const lo = anchor < k ? anchor : k, hi = anchor < k ? k : anchor;
      field.value = base + (lo === hi ? lo : lo + ".." + hi);
      anchor = "";
    }
    mine = true;
    field.dispatchEvent(new Event("input", { bubbles: true }));
    mine = false;
    marks();
  };
  const step = (k, dx, dy) => {
    if (data.unit === "day") {
      const d = new Date(Date.UTC(+k.slice(0, 4), +k.slice(5, 7) - 1, +k.slice(8, 10) + dx + 7 * dy));
      return d.getUTCFullYear() + "-" + two(d.getUTCMonth() + 1) + "-" + two(d.getUTCDate());
    }
    const d = new Date(Date.UTC(+k.slice(0, 4), +k.slice(5, 7) - 1 + dx + 4 * dy, 1));
    return d.getUTCFullYear() + "-" + two(d.getUTCMonth() + 1);
  };
  root.addEventListener("click", (e) => {
    const b = e.target.closest("button.cal__day");
    if (b) pick(b, e);
  });
  root.addEventListener("keydown", (e) => {
    const b = e.target.closest("button.cal__day");
    if (!b) return;
    const move = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[e.key];
    if (!move) {
      if (e.key === "PageUp" || e.key === "PageDown") {
        e.preventDefault();
        const to = e.key === "PageUp" ? data.prev : data.next;
        if (to) load(to);
      }
      return;
    }
    e.preventDefault();
    const to = step(b.dataset.key, move[0], move[1]);
    const at = root.querySelector('button[data-key="' + to + '"]');
    if (at) {
      focus = to;
      for (const x of root.querySelectorAll("button.cal__day")) x.tabIndex = x === at ? 0 : -1;
      at.focus();
    } else {
      const p = data.unit === "day" ? to.slice(0, 7) : to.slice(0, 4);
      if ((to < b.dataset.key ? data.prev : data.next) === p) load(p, to);
    }
  });
  field.addEventListener("input", () => {
    if (!mine) anchor = "";
    if (data) marks();
  });
  const first = ranges()[0];
  root.hidden = false;
  root.textContent = "Loading calendar…";
  load(first ? first[0].slice(0, data_len(first[0])) : "");
  function data_len(k) { return k.length === 4 ? 4 : 7; }
})();
"""
"""The Start runs form's calendar: a month of days (a year of months for a
monthly pipeline) from `<pipeline>/calendar`, each coloured by its state.
Two clicks fill the range field, which the preview and command lines already
follow; the arrows move between days, Page Up and Down between months."""


comptime _START_SCRIPT = """
(() => {
  const f = document.getElementById("start");
  if (!f) return;
  const sh = (s) => /^[A-Za-z0-9_.,:\\/@=+%-]+$/.test(s) ? s : "'" + s.replaceAll("'", "'\\\\''") + "'";
  let timer;
  const update = () => {
    const keys = f.elements.partitions.value.trim();
    const rerun = f.elements.rerun.checked;
    const k = keys ? sh(keys) : "<range>";
    const u = location.origin;
    f.querySelector("[data-cmd=backfill]").textContent = "morca login " + u + " && morca --remote " + u +
      " backfill " + (rerun ? "--rerun " : "") + f.dataset.pipeline + " " + k;
    clearTimeout(timer);
    if (!keys) return;
    timer = setTimeout(async () => {
      const q = new URLSearchParams({ preview: "1", partitions: keys });
      if (rerun) q.set("rerun", "1");
      try {
        const r = await fetch(f.dataset.page + "?" + q);
        const doc = new DOMParser().parseFromString(await r.text(), "text/html");
        const got = doc.getElementById("start-preview");
        const at = document.getElementById("start-preview");
        if (got && at) at.replaceWith(got);
      } catch (e) {}
    }, 400);
  };
  f.addEventListener("input", update);
  f.addEventListener("change", update);
})();
"""
"""Updates the Start runs form's command line as you type, and its
preview a moment after; without it, the Preview button does the same."""


def start_html(
    mut h: Html,
    p: PipelineRow,
    keys: String,
    rerun: Bool,
    preview: Optional[StartPreview],
    keys_per_run: Int,
):
    """The pipeline page's Start runs section: one range, a backfill (the
    primary) or one run over it, a preview of what they'd queue, and the
    same from the command line."""
    var base = String("/pipelines/", url_encode(p.name))
    var unit = unit_word(p.kind, 1)
    var units = unit_word(p.kind, 2)
    var example = example_of(p.kind)
    h.raw(
        "<h2>Start runs",
        docs_link("cli"),
        '</h2><form class="start" id="start"',
    )
    h.raw(' method="post" action="')
    h.text(base, "/backfill")
    h.raw('" data-page="')
    h.text(base)
    h.raw('" data-pipeline="')
    h.text(shell_quote(p.name))
    h.raw('" data-binary="')
    h.text(shell_quote(p.binary))
    h.raw('"><label class="start__range">')
    h.text("Keys" if p.kind == "keyed" else String("Range of ", units))
    h.raw(' <input name="partitions" required placeholder="')
    if p.kind == "keyed":
        h.text("@all, or name,name")
    else:
        h.text(example, "..", example)
    h.raw('" value="')
    h.text(keys)
    h.raw('"></label>')
    if p.kind == "daily" or p.kind == "monthly":
        # Filled in by _CAL_SCRIPT; without scripts it stays hidden and the
        # field above is the form.
        h.raw('<div class="cal" hidden data-calendar="')
        h.text(base, "/calendar")
        h.raw('"></div>')
    h.raw('<label class="start__check"><input type="checkbox"')
    h.raw(' name="rerun" value="1"', " checked" if rerun else "", ">")
    h.text(" Include ", units, " that already succeeded (rerun them)")
    h.raw('</label><div class="start__choices"><div class="start__choice">')
    h.raw('<button type="submit" class="primary">')
    if keys_per_run > 1:
        h.text("Backfill: runs of up to ", keys_per_run, " ", units)
    else:
        h.text("Backfill: one run per ", unit)
    h.raw('</button><p class="muted">')
    h.text(
        "Queues a run for each ",
        unit if keys_per_run <= 1 else String(keys_per_run, " ", units),
        " in the range that hasn't succeeded and isn't in a queued or",
        " running run.",
    )
    h.raw('</p></div><div class="start__choice"><button type="submit"')
    h.raw(' formaction="')
    h.text(base, "/runs")
    h.raw('">Start one run over the whole range</button><p class="muted">')
    h.text(
        "Queues a single run over every ",
        unit,
        " in the range, done or not; refused while a queued or running run",
        " has one of them.",
    )
    h.raw("</p></div></div>")
    h.raw('<button type="submit" formmethod="get" formaction="')
    h.text(base, "#start")
    h.raw('" formnovalidate name="preview" value="1">Preview</button>')
    h.raw('<div id="start-preview" class="start__preview">')
    if preview:
        ref v = preview.value()
        if v.refused:
            h.raw('<p class="refused">')
            h.text(v.refused)
            h.raw("</p>")
        else:
            h.raw('<p data-preview="backfill">')
            h.text(preview_line(p, v))
            h.raw('</p><p class="muted" data-preview="run">')
            h.text(one_run_line(p, v))
            h.raw("</p>")
    h.raw('</div><p class="muted start__cli">From the command line:</p>')
    cmd_box(h, "backfill", remote_cmd(backfill_cmd(p.name, keys, rerun)))
    h.raw("</form><script>", _START_SCRIPT)
    if p.kind == "daily" or p.kind == "monthly":
        h.raw(_CAL_SCRIPT)
    h.raw("</script>")
