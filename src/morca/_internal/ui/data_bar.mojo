"""The bar at the top of a dataset's Data tab (#499): which commit (Iceberg
snapshot) it shows, picked from a searchable list of them, newest first,
with arrows to the one before and after, and how many rows it holds.

Each commit in the list is a link to the tab at it (`?snapshot=<id>`), so
the URL says which one is shown, and the filters, columns, sort and chart
asked for stay as they are. Without one in the URL, the newest is shown.
The search box filters the list as one types (`PICK_JS`); without
JavaScript the list is there to scroll, and the links work the same.
"""

from json import Value

from morca._internal.html import Html
from morca._internal.lineage import SnapshotRef
from morca._internal.ui.datasets import dataset_href, snapshot_href
from morca._internal.ui.runs import grouped
from morca._internal.views.data import DataQuery

comptime SHORT_ID = 8
"""The digits of a snapshot id shown in the bar; the rest are in its
title and the URL."""


def data_href(name: String, q: DataQuery, cursor: Int = 0) -> String:
    """The dataset's Data tab as `q` asks for it, at `cursor`."""
    return String(dataset_href(name), "?tab=data", q.query(cursor))


def short_id(id: Int) -> String:
    var s = String(id)
    if s.byte_length() <= SHORT_ID:
        return s^
    return String(s[byte=:SHORT_ID])


def _when(at: String) -> String:
    """`2024-01-02T03:04:05.678Z` as `2024-01-02 03:04`."""
    if at.byte_length() < 16:
        return at
    return String(at[byte=:10], " ", at[byte=11:16])


def commit_message(s: Value) raises -> String:
    """What a commit did, as a line: its operation, the run that made it
    and its partitions, and the rows it added."""
    var out = String(s.at("/operation").string_value())
    var run = s.at("/run").string_value()
    if run:
        out.write(" · run ", run)
    var parts = s.at("/partitions").string_value()
    if parts:
        out.write(" · ", parts)
    out.write(" · +", grouped(Int(s.at("/added_records").int_value())))
    return out^


def _at(name: String, q: DataQuery, id: Int) -> String:
    var q2 = q.copy()
    q2.snapshot = String(id)
    return data_href(name, q2)


def _step(
    mut h: Html,
    name: String,
    q: DataQuery,
    to: Optional[Int],
    rel: StaticString,
    label: StaticString,
    arrow: StaticString,
):
    if to:
        h.raw('<a class="dbar__step" rel="', rel, '" href="')
        h.text(_at(name, q, to.value()))
        h.raw('" title="', label, '" aria-label="', label, '">', arrow, "</a>")
    else:
        h.raw(
            '<span class="dbar__step" aria-disabled="true" title="',
            label,
            '">',
            arrow,
            "</span>",
        )


def commit_bar(mut h: Html, name: String, q: DataQuery, v: Value) raises:
    """The bar (the module doc), over the read's `snapshots` (newest
    first) and the `snapshot` it read."""
    var at = v.at("/snapshot")
    var snaps = v.at("/snapshots").array_items()
    var pos = -1
    if not at.is_null():
        for i in range(len(snaps)):
            if snaps[i].at("/snapshot").int_value() == at.int_value():
                pos = i
    h.raw('<div class="dbar" role="group" aria-label="Commit">')
    if at.is_null():
        h.raw('<span class="dbar__none">No commits yet.</span></div>')
        return
    var older = Optional[Int](None)
    var newer = Optional[Int](None)
    if pos >= 0 and pos + 1 < len(snaps):
        older = Int(snaps[pos + 1].at("/snapshot").int_value())
    if pos > 0:
        newer = Int(snaps[pos - 1].at("/snapshot").int_value())
    _step(h, name, q, older, "prev", "Older commit", "‹")
    h.raw('<details class="pick dpick"><summary><span class="pick__value"')
    h.raw(' title="')
    h.text("snapshot ", at.int_value())
    h.raw('"><code>')
    h.text(short_id(Int(at.int_value())))
    h.raw("</code>")
    if pos >= 0:
        h.raw(' <span class="muted">')
        h.text(_when(snaps[pos].at("/at").string_value()))
        h.raw("</span>")
    if pos == 0:
        h.raw(' <span class="dpick__latest">latest</span>')
    h.raw('</span></summary><div class="pick__menu dpick__menu">')
    h.raw(
        '<input type="search" class="dpick__search" hidden',
        ' placeholder="Search commits" aria-label="Search commits">',
        '<ul class="dpick__list" aria-label="Commits, newest first">',
    )
    for i in range(len(snaps)):
        ref s = snaps[i]
        var id = Int(s.at("/snapshot").int_value())
        var msg = commit_message(s)
        var when = _when(s.at("/at").string_value())
        h.raw('<li><a class="dpick__item" href="')
        h.text(_at(name, q, id))
        h.raw('" data-search="')
        h.text(String(id, " ", msg, " ", when).lower())
        h.raw('"', ' aria-current="true"' if i == pos else "", '><code title="')
        h.text(id)
        h.raw('">')
        h.text(short_id(id))
        h.raw('</code> <span class="dpick__msg">')
        h.text(msg)
        h.raw('</span> <span class="dpick__when">')
        h.text(when)
        h.raw("</span></a></li>")
    h.raw("</ul>")
    var total = Int(v.at("/snapshots_total").int_value())
    if total > len(snaps):
        h.raw(
            '<p class="card__sub">The newest ',
            grouped(len(snaps)),
            " of ",
            grouped(total),
            " commits.</p>",
        )
    h.raw("</div></details>")
    _step(h, name, q, newer, "next", "Newer commit", "›")
    h.raw('<span class="dbar__rows">')
    if pos >= 0:
        var rows = Int(snaps[pos].at("/total_records").int_value())
        if rows >= 0:
            h.raw("<strong>", grouped(rows), "</strong> rows")
    h.raw("</span>")
    h.raw('<span class="dbar__more">')
    h.link(snapshot_href(SnapshotRef(name, at.int_value())), "Lineage")
    h.raw("</span></div>")


comptime PICK_JS = """
(() => {
  for (const box of document.querySelectorAll(".dpick__search")) {
    const pick = box.closest("details");
    const items = [...pick.querySelectorAll(".dpick__item")];
    box.hidden = false;
    box.addEventListener("input", () => {
      const q = box.value.trim().toLowerCase();
      for (const a of items) a.parentElement.hidden = !!q && !a.dataset.search.includes(q);
    });
    box.addEventListener("keydown", (e) => {
      if (e.key === "Escape") { pick.open = false; return; }
      if (e.key !== "Enter") return;
      e.preventDefault();
      const a = items.find((a) => !a.parentElement.hidden);
      if (a) a.click();
    });
    pick.addEventListener("toggle", () => {
      if (!pick.open) return;
      box.focus();
      const cur = pick.querySelector("[aria-current]");
      if (cur) cur.scrollIntoView({ block: "nearest" });
    });
  }
  document.addEventListener("click", (e) => {
    for (const d of document.querySelectorAll("details.dpick[open]"))
      if (!d.contains(e.target)) d.open = false;
  });
})();
"""
"""The commit list's search box (the module doc): typing filters the list,
Enter opens the first left, Escape closes it, and a click outside does too."""
