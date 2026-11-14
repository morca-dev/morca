"""The stylesheet `morca ui` serves at `/static/morca.css`: magmalake.dev's
colours and type, light and dark, and system fonts (nothing is fetched)."""

comptime STYLE = """:root {
  --bg: #fbf9f7; --bg-alt: #f4f0ec; --surface: #ffffff; --surface-2: #f8f5f2;
  --border: #e3dcd4; --border-strong: #cfc5ba;
  --text: #17151a; --muted: #6b645d; --faint: #948c84;
  --ember: #c33c10; --ember-soft: #e8631f; --ember-wash: #fdefe7;
  --lake: #0d6a70; --lake-soft: #14868d; --lake-wash: #e6f2f2;
  --ok: #1f7a3d; --bad: #b42318; --warn: #9a5b00; --live: #1d5fb4;
  --shadow: 0 1px 2px rgb(23 21 26 / 0.04), 0 8px 24px -12px rgb(23 21 26 / 0.12);
  --radius: 10px; --radius-sm: 6px;
  --mono: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  --sans: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  color-scheme: light dark;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0e0d11; --bg-alt: #131218; --surface: #17161d; --surface-2: #1c1b23;
    --border: #2a2833; --border-strong: #3d3a48;
    --text: #eeeae4; --muted: #a49d95; --faint: #7b746d;
    --ember: #ff7a45; --ember-soft: #ff9466; --ember-wash: #2a1710;
    --lake: #4ecdc4; --lake-soft: #7bddd6; --lake-wash: #0f2422;
    --ok: #5fd08a; --bad: #ff7b72; --warn: #f0b24a; --live: #6ea8fe;
    --shadow: 0 1px 2px rgb(0 0 0 / 0.4), 0 8px 24px -12px rgb(0 0 0 / 0.6);
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 var(--sans);
  -webkit-font-smoothing: antialiased; }
a { color: var(--lake); text-decoration-color: color-mix(in srgb, var(--lake) 35%, transparent);
  text-underline-offset: 0.18em; }
a:hover { text-decoration-color: currentColor; }
code, pre { font-family: var(--mono); font-size: 0.9em; }
code { background: var(--surface-2); border: 1px solid var(--border); border-radius: 4px;
  padding: 0.05em 0.35em; }
pre { white-space: pre-wrap; }
pre code { background: none; border: 0; padding: 0; }

/* The header: the mark, the sections, and who's logged in. */
.top { display: flex; align-items: stretch; gap: 1.75rem; padding: 0 1.25rem; min-height: 3.5rem;
  background: var(--surface); border-bottom: 1px solid var(--border);
  box-shadow: 0 1px 0 color-mix(in srgb, var(--ember) 10%, transparent), var(--shadow);
  position: relative; z-index: 1; }
.top__brand { display: flex; align-items: center; gap: 0.55rem; font-weight: 700;
  font-size: 1.1rem; letter-spacing: -0.02em; color: var(--text); text-decoration: none; }
.top__mark { display: block; flex-shrink: 0; }
.top nav { display: flex; gap: 1.25rem; }
.top nav a { display: flex; align-items: center; color: var(--muted); text-decoration: none;
  font-size: 0.9375rem; border-bottom: 2px solid transparent; margin-bottom: -1px; }
.top nav a:hover { color: var(--text); }
.top nav a[aria-current] { color: var(--text); font-weight: 600; border-bottom-color: var(--ember); }
.menu { position: relative; display: flex; }
.menu__sub { display: none; position: absolute; top: 100%; left: -0.75rem; min-width: 9rem;
  flex-direction: column; padding: 0.35rem 0; background: var(--surface);
  border: 1px solid var(--border); border-radius: var(--radius-sm); box-shadow: var(--shadow); }
.menu:hover .menu__sub, .menu:focus-within .menu__sub { display: flex; }
.top nav .menu__sub a { padding: 0.45rem 0.85rem; margin: 0; border: 0; white-space: nowrap; }
.top nav .menu__sub a:hover { background: var(--surface-2); }
.top nav a:focus-visible { outline: 2px solid var(--lake); outline-offset: 2px; border-radius: 2px; }
.top__user { display: flex; align-items: center; gap: 0.5rem; margin-left: auto;
  color: var(--muted); font-size: 0.9375rem; }
a.top__user { color: var(--lake); }
.top__user form { display: inline; }
.top__user button { font: inherit; color: var(--muted); background: none; border: 0;
  padding: 0; cursor: pointer; text-decoration: underline; }
.top__user button:hover { color: var(--text); }
@media (max-width: 640px) {
  .top { flex-wrap: wrap; gap: 0 1rem; padding: 0 1rem; }
  .top__brand, .top__user { min-height: 3rem; }
  .top nav { order: 3; width: 100%; gap: 1rem; overflow-x: auto; }
  .top nav a { padding: 0.35rem 0 0.5rem; white-space: nowrap; }
  /* The nav scrolls sideways here, which would clip a dropdown: show the
     submenu inline, after "Ops". */
  .menu { gap: 1rem; }
  .menu__sub, .menu:hover .menu__sub, .menu:focus-within .menu__sub { display: flex; position: static;
    flex-direction: row; gap: 1rem; padding: 0; min-width: 0; border: 0; box-shadow: none; background: none; }
  .top nav .menu__sub a { padding: 0.35rem 0 0.5rem; }
  .top nav .menu__sub a:hover { background: none; }
}

main { max-width: 72rem; margin: 0 auto; padding: 1.75rem 1.25rem 3rem; }
@media (max-width: 640px) { main { padding: 1.25rem 1rem 2.5rem; } }
h1 { font-size: 1.6rem; letter-spacing: -0.02em; line-height: 1.2; margin: 0.2rem 0 1rem; }
h2 { font-size: 1.1rem; letter-spacing: -0.01em; margin: 2rem 0 0.7rem; }
.crumb { margin: 0 0 0.3rem; color: var(--muted); font-size: 0.875rem; }
.muted, .empty { color: var(--muted); }
.empty { background: var(--surface); border: 1px dashed var(--border-strong);
  border-radius: var(--radius); padding: 1rem 1.2rem; }
.more { font-size: 0.875rem; }
.error { color: var(--bad); }

/* A section of the home page: a heading, then its table or chart. */
.card { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
  box-shadow: var(--shadow); margin: 1.25rem 0; overflow: hidden; }
.card > h2 { font-size: 0.9375rem; margin: 0; padding: 0.75rem 1.1rem;
  border-bottom: 1px solid var(--border); background: var(--surface-2); }
/* A heading that links to its own section, so a page can be linked to it. */
.card > h2 > a.anchor { color: inherit; text-decoration: none; }
.card > h2 > a.anchor:hover::after { content: " #"; color: var(--muted); }
.card > p { margin: 0; padding: 0.8rem 1.1rem; }
.card > .muted { font-size: 0.875rem; border-bottom: 1px solid var(--border); }
.card > .scroll { padding: 0; }
.card > .scroll > .tl { padding: 1rem 1.1rem 0.6rem; }
.card > table, .card > .scroll > table { border: 0; border-radius: 0; box-shadow: none; }
.card > h2 + .scroll { border-top: 0; }

/* Tables: hairline rows, a tinted header, hover, and the numbers lined up. */
.scroll { overflow-x: auto; -webkit-overflow-scrolling: touch; }
table { border-collapse: separate; border-spacing: 0; width: 100%; background: var(--surface);
  border: 1px solid var(--border); border-radius: var(--radius); font-size: 0.875rem;
  overflow: hidden; }
th, td { text-align: left; padding: 0.5rem 0.7rem; border-bottom: 1px solid var(--border);
  vertical-align: top; }
th { color: var(--faint); font-family: var(--mono); font-weight: 500; font-size: 0.6875rem;
  text-transform: uppercase; letter-spacing: 0.08em; background: var(--surface-2);
  white-space: nowrap; }
td { white-space: nowrap; }
tbody tr:last-child td { border-bottom: 0; }
tbody tr:hover td { background: color-mix(in srgb, var(--ember) 3%, transparent); }
.mono { font-family: var(--mono); font-size: 0.78rem; font-variant-numeric: tabular-nums; }
th.num, td.num { text-align: right; font-variant-numeric: tabular-nums; }
td.num { font-family: var(--mono); font-size: 0.78rem; }
td.parts { max-width: 22rem; overflow: hidden; text-overflow: ellipsis; }
details.all-parts > summary { cursor: pointer; color: var(--muted); font-size: 0.85rem; }
details.all-parts > div { max-height: 16rem; overflow-y: auto; overflow-wrap: anywhere; margin-top: 0.3rem; }
/* A cell listing pipelines or datasets: wraps between names, never inside one. */
td.names { white-space: normal; max-width: 22rem; }
td.names a { white-space: nowrap; }
td.error { white-space: normal; color: var(--bad); font-family: var(--mono); font-size: 0.8rem; max-width: 32rem; }
td code { font-size: 0.8125rem; }
/* A pipeline's coverage on the home page: the percent over a thin bar. */
.covpct { display: inline-grid; gap: 2px; min-width: 3.2rem; color: var(--text); text-decoration: none; }
.covpct:hover { color: var(--lake); }
.covpct__bar { display: block; height: 3px; border-radius: 2px; overflow: hidden;
  background: var(--surface-2); box-shadow: inset 0 0 0 1px var(--border); }
.covpct__bar > span { display: block; height: 100%; background: var(--ok); }
/* A batch of runs on the home page: how many have ended, under its counts. */
.batch__bar { max-width: 12rem; margin-top: 3px; }

/* A run's number, a count, a status. */
.chip { display: inline-block; font-family: var(--mono); font-size: 0.75rem; line-height: 1.5;
  font-variant-numeric: tabular-nums; color: var(--text); text-decoration: none;
  background: var(--surface-2); border: 1px solid var(--border); border-radius: var(--radius-sm);
  padding: 0 0.45rem; }
.chip::before { content: "#"; color: var(--faint); margin-right: 0.05em; }
.chip:hover { border-color: var(--lake); color: var(--lake); }
.badge { display: inline-block; font-family: var(--mono); font-size: 0.75rem; line-height: 1.5;
  font-variant-numeric: tabular-nums; color: var(--muted); background: var(--surface-2);
  border: 1px solid var(--border); border-radius: 999px; padding: 0 0.55rem; white-space: nowrap; }
.badge--running { color: var(--live); background: color-mix(in srgb, var(--live) 10%, transparent);
  border-color: color-mix(in srgb, var(--live) 30%, transparent); font-weight: 600; }
.badge--queued { color: var(--warn); background: color-mix(in srgb, var(--warn) 10%, transparent);
  border-color: color-mix(in srgb, var(--warn) 30%, transparent); font-weight: 600; }
.status { display: inline-block; font-family: var(--mono); font-size: 0.75rem; line-height: 1.5;
  padding: 0 0.55rem; border-radius: 999px; white-space: nowrap; font-weight: 500;
  color: var(--muted); background: var(--surface-2); border: 1px solid var(--border); }
.status--succeeded { color: var(--ok); background: color-mix(in srgb, var(--ok) 10%, transparent);
  border-color: color-mix(in srgb, var(--ok) 30%, transparent); }
.status--failed { color: var(--bad); background: color-mix(in srgb, var(--bad) 10%, transparent);
  border-color: color-mix(in srgb, var(--bad) 30%, transparent); }
.status--running { color: var(--live); background: color-mix(in srgb, var(--live) 10%, transparent);
  border-color: color-mix(in srgb, var(--live) 30%, transparent); }
.status--running::before { content: ""; display: inline-block; width: 0.45em; height: 0.45em;
  border-radius: 50%; background: currentColor; margin-right: 0.45em; vertical-align: 0.1em;
  animation: pulse 1.6s ease-in-out infinite; }
@keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.3; } }
@media (prefers-reduced-motion: reduce) { .status--running::before { animation: none; } }
.status--queued, .status--pending { color: var(--warn);
  background: color-mix(in srgb, var(--warn) 10%, transparent);
  border-color: color-mix(in srgb, var(--warn) 30%, transparent); }
.status--cancelled, .status--deferred { color: var(--muted); background: var(--surface-2); border-color: var(--border-strong); }
.status--skipped, .status--not-done { color: var(--faint); background: transparent;
  border-style: dashed; }
/* A machine's state on Pools (morca.ui.pools): live, draining, gone. */
.status--live { color: var(--ok); background: color-mix(in srgb, var(--ok) 10%, transparent);
  border-color: color-mix(in srgb, var(--ok) 30%, transparent); }
.status--draining { color: var(--warn); background: color-mix(in srgb, var(--warn) 10%, transparent);
  border-color: color-mix(in srgb, var(--warn) 30%, transparent); }
.status--gone { color: var(--faint); background: transparent; border-style: dashed; }
tr.pools__gone td { color: var(--muted); }
/* Ops › Alerts (morca.ui.alerts): an open alert's row, the message under its title. */
tr.alerts__open td { background: color-mix(in srgb, var(--bad) 6%, transparent); }
tr.alerts__open td:first-child { box-shadow: inset 3px 0 0 var(--bad); }
td.alerts__msg { white-space: normal; min-width: 16rem; max-width: 34rem; }
td.alerts__links { white-space: normal; max-width: 13rem; }
td.alerts__delivery { white-space: normal; max-width: 14rem; }
.alerts__err { display: block; margin-top: 0.2rem; font-family: var(--mono); font-size: 0.75rem; color: var(--bad); }
td.alerts__state time { font-size: 0.75rem; color: var(--muted); }
.alerts__body { display: block; color: var(--muted); font-size: 0.8125rem; white-space: pre-line; }
.alerts__kind { white-space: nowrap; }
.alerts__summary { margin: 0 0 0.8rem; font-size: 0.875rem; color: var(--muted); }
.alerts__summary strong { color: var(--bad); }
.pools__pools { margin: -0.25rem 0 1rem; }
h1 .status, h2 .status { vertical-align: middle; margin-left: 0.5rem; }

/* Facts about a pipeline, a run, a dataset. */
.facts { display: grid; grid-template-columns: max-content 1fr; gap: 0.35rem 1.4rem; margin: 0 0 0.5rem;
  font-size: 0.9375rem; }
.facts dt { color: var(--muted); }
.facts dd { margin: 0; overflow-wrap: anywhere; }

/* The pipeline page's cards: Progress, Config, Code and Resources side by
   side where there's room, one above the other where there isn't. */
.pcards { display: grid; grid-template-columns: repeat(auto-fit, minmax(19rem, 1fr)); gap: 1rem;
  align-items: start; margin: 1rem 0 1.25rem; }
.pcards > .card { margin: 0; }
.pcards--one { grid-template-columns: 1fr; }

/* The pipeline page's tabs: Overview, Runs and Operate, each its own page. */
/* overflow-y: hidden, since overflow-x: auto alone makes y auto too, and the
   tabs' -1px margin over the border then overflowed: a vertical scrollbar. */
.ptabs { display: flex; gap: 1.5rem; margin: 0 0 1rem; border-bottom: 1px solid var(--border);
  overflow-x: auto; overflow-y: hidden; }
.ptabs__tab { padding: 0.4rem 0.1rem 0.55rem; margin-bottom: -1px; color: var(--muted);
  text-decoration: none; border-bottom: 2px solid transparent; white-space: nowrap; }
.ptabs__tab:hover { color: var(--text); }
.ptabs__tab[aria-current] { color: var(--text); font-weight: 600; border-bottom-color: var(--ember); }
.ptabs__tab:focus-visible { outline: 2px solid var(--lake); outline-offset: -2px; border-radius: 2px; }
.card--facts { overflow: visible; }
.card--facts > h2 { border-radius: var(--radius) var(--radius) 0 0; }
.card > .facts, .card > div > .facts { padding: 0.8rem 1.1rem; margin: 0; gap: 0.45rem 1.1rem;
  font-size: 0.875rem; }
.card > p.hash { font-size: 0.75rem; color: var(--faint); border-top: 1px solid var(--border);
  padding: 0.5rem 1.1rem; }
.card > p.hash code { font-size: 0.95em; color: var(--muted); }
.card--facts a.src { font-size: 0.8125rem; }
.card > p.card__none { padding: 0.8rem 1.1rem; margin: 0; font-size: 0.875rem; color: var(--muted); }

/* The run page's cards: a line under the heading saying what the card
   is, a plain warning when its numbers aren't the run's alone, and the
   run's actions at the foot of its Status card. */
.card > p.card__sub { padding: 0.55rem 1.1rem; font-size: 0.8125rem; color: var(--muted);
  border-bottom: 1px solid var(--border); }
.card > p.card__warn { padding: 0.55rem 1.1rem; font-size: 0.8125rem; color: var(--warn);
  background: color-mix(in srgb, var(--warn) 8%, transparent); border-bottom: 1px solid var(--border); }
.card > .actions { margin: 0; padding: 0.7rem 1.1rem 0.9rem; border-top: 1px solid var(--border); }
.card > .mx__legend { padding: 0.55rem 1.1rem 0; border-bottom: 0; }
.card > .scroll > .mx { padding: 0 1.1rem; }
.facts code.env { font-size: 0.8125rem; }
/* A long link to code in a card wraps rather than widening a phone's page. */
.card--facts dd a.src { white-space: normal; overflow-wrap: anywhere; }
.steps__graph > .tl { margin: 0.25rem 0; }

/* The lineage diagram's legend. */
.card > .graph__legend { padding: 0.55rem 1.1rem; font-size: 0.8125rem; }
.graph__key { display: inline-block; width: 1.4em; height: 0.85em; margin: 0 0.35em 0 0.8em;
  vertical-align: -0.1em; border: 1.5px solid var(--border-strong); border-radius: 3px;
  background: var(--surface); }
.graph__key:first-child { margin-left: 0; }
.graph__key--start { border: 2.5px solid var(--ember); }
.graph__key--source { border-style: dashed; }
.graph__key--other { border-style: dotted; opacity: 0.7; }
.graph__node--other rect { stroke-dasharray: 2 3; }
.graph__node--other text { opacity: 0.75; }
.graph__arrow { margin-left: 0.8em; color: var(--faint); }
.card > .scroll > .graph { margin: 0.75rem auto; }

/* The Steps card: its heading with Graph and Table tabs. */
.steps__head { display: flex; flex-wrap: wrap; gap: 0.5rem 1rem; align-items: center;
  justify-content: space-between; padding: 0.5rem 1.1rem; border-bottom: 1px solid var(--border);
  background: var(--surface-2); }
.steps__head h2 { font-size: 0.9375rem; margin: 0; }
.steps__graph { padding: 0.5rem 1.1rem; }
.steps__head .vtabs { margin: 0; }
a.vtabs__tab { display: inline-block; text-decoration: none; }

/* A "?" after a fact's name: its help on hover or keyboard focus. */
.help { position: relative; display: inline-block; margin-left: 0.35rem; vertical-align: 0.08em; }
.help__btn { display: inline-grid; place-items: center; width: 1rem; height: 1rem; padding: 0;
  border-radius: 50%; font: 600 0.625rem/1 var(--sans); color: var(--faint);
  background: transparent; border: 1px solid var(--border-strong); cursor: help; }
.help__btn:hover, .help:focus-within .help__btn { color: var(--lake); border-color: var(--lake); }
.help__tip { display: none; position: absolute; z-index: 20; top: calc(100% + 0.4rem); left: -0.6rem;
  width: max-content; max-width: min(20rem, 80vw); padding: 0.55rem 0.75rem; text-align: left;
  background: var(--surface); color: var(--text); border: 1px solid var(--border-strong);
  border-radius: var(--radius-sm); box-shadow: var(--shadow); font: 400 0.8125rem/1.45 var(--sans);
  letter-spacing: 0; text-transform: none; white-space: normal; }
.help__tip::before { content: ""; position: absolute; left: 0; right: 0; top: -0.5rem; height: 0.5rem; }
.help:hover .help__tip, .help:focus-within .help__tip { display: block; }
.help.help--shut .help__tip { display: none; }

/* In a table, which scrolls sideways, a "?"'s help escapes the box: fixed,
   placed under its button by the page script (`_TIPS`). */
.scroll .help__tip { position: fixed; top: auto; left: auto; }
.scroll .help__tip::before { display: none; }
th .help { margin-left: 0.25rem; vertical-align: 0; }

/* A value from a fixed set (a status, a step's kind, a trigger, a
   placement): what it means on hover, keyboard focus or a tap, in one
   floating box the page script places (`_TIPS`). */
.term { text-decoration: underline dotted var(--muted); text-underline-offset: 0.2em; }
[data-tip] { cursor: help; }
[data-tip]:focus-visible { outline: 2px solid var(--lake); outline-offset: 1px; }
.help__tip.tip { position: fixed; display: none; top: 0; left: 0; }
.help__tip.tip::before { display: none; }

/* A function's source, shown on hovering a link to it. */
.peek { position: absolute; z-index: 30; width: min(42rem, calc(100vw - 1rem));
  background: var(--surface); border: 1px solid var(--border-strong); border-radius: var(--radius-sm);
  box-shadow: var(--shadow); overflow: hidden; }
.peek__head { padding: 0.35rem 0.75rem; font: 0.75rem var(--mono); color: var(--muted);
  background: var(--surface-2); border-bottom: 1px solid var(--border); }
.peek__head span { color: var(--faint); }
.peek pre { margin: 0; padding: 0.4rem 0; max-height: 24rem; overflow: auto; white-space: pre;
  font-size: 0.75rem; line-height: 1.5; }
.peek__line { display: block; padding-right: 0.75rem; }
.peek__line--at { background: color-mix(in srgb, var(--lake) 12%, transparent); }
.peek__ln { display: inline-block; width: 3.4em; padding-right: 0.9em; text-align: right;
  color: var(--faint); user-select: none; }
.peek__lead { margin: 0; padding: 0.55rem 0.75rem 0; font: 500 0.875rem/1.45 var(--sans); color: var(--text); }
.peek__more { margin: 0; padding: 0.2rem 0.75rem 0; font-size: 0.8125rem; line-height: 1.45; color: var(--muted);
  display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 3; line-clamp: 3; overflow: hidden; }
.peek__lead + pre, .peek__more + pre { margin-top: 0.35rem; border-top: 1px solid var(--border); }
.peek__msg { margin: 0; padding: 0.6rem 0.75rem; color: var(--muted); font-size: 0.8125rem; }
/* A step's card (morca.ui.step_cards), on hovering, focusing or tapping a step
   in the steps views: its signature, kind, types, datasets and recent
   runs, or on a run's page the attempt's. */
[data-step] { cursor: help; }
.step-ref { text-decoration: underline dotted var(--muted); text-underline-offset: 0.2em; }
[data-step]:focus-visible { outline: 2px solid var(--lake); outline-offset: 1px; }
.scard { position: fixed; z-index: 30; width: min(28rem, calc(100vw - 1rem)); max-height: 70vh; overflow: auto;
  background: var(--surface); border: 1px solid var(--border-strong); border-radius: var(--radius-sm);
  box-shadow: var(--shadow); font-size: 0.8125rem; color: var(--text); }
.scard__head { padding: 0.45rem 0.75rem; background: var(--surface-2); border-bottom: 1px solid var(--border); }
.scard__sig { margin: 0; padding: 0.5rem 0.75rem; white-space: pre-wrap; overflow-wrap: anywhere;
  font-size: 0.75rem; line-height: 1.5; border-bottom: 1px solid var(--border); }
.scard__doc { margin: 0; padding: 0.45rem 0.75rem 0; color: var(--muted); font-size: 0.8125rem;
  display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 4; line-clamp: 4; overflow: hidden; }
.scard__lead { margin: 0; padding: 0.5rem 0.75rem 0.4rem; font-weight: 500; }
.scard__src { margin: 0; padding: 0.3rem 0.75rem 0; font: 0.75rem var(--mono); }
.scard__facts { display: grid; grid-template-columns: max-content 1fr; gap: 0.2rem 0.75rem;
  margin: 0; padding: 0.5rem 0.75rem 0.6rem; }
.scard__facts dt { color: var(--muted); }
.scard__facts dd { margin: 0; min-width: 0; overflow-wrap: anywhere; }
.help__tip.tip { z-index: 40; }  /* a kind's meaning, over the card */
/* Its colours (morca.highlight), from the theme's tokens. */
.hl--kw { color: var(--ember); }
.hl--fn { color: var(--live); font-weight: 600; }
.hl--str { color: var(--ok); }
.hl--com { color: var(--faint); font-style: italic; }
.hl--num, .hl--const { color: var(--lake); }
.hl--dec { color: var(--warn); }

/* Forms: filters, actions, and logging in. */
.filters { display: flex; flex-wrap: wrap; gap: 0.6rem 1rem; align-items: end; margin-bottom: 1rem; }
.filters label { display: grid; gap: 0.2rem; font-size: 0.8rem; color: var(--muted); }
.filters input[type=search] { min-width: 0; }
/* One height for every control in a filter row: selects, date and text
   inputs, the status picker and the button differ by browser otherwise. */
.filters select, .filters input:not([type=checkbox]), .filters .pick__value,
.filters button { box-sizing: border-box; height: 2.25rem; padding-top: 0; padding-bottom: 0;
  line-height: calc(2.25rem - 2px); font: inherit; font-size: 0.875rem; }
.filters select { padding-left: 0.5rem; padding-right: 1.6rem; border: 1px solid var(--border-strong);
  border-radius: var(--radius-sm); background: var(--surface); color: var(--text); }
.filters__quick { display: flex; flex-wrap: wrap; gap: 0.2rem 0.7rem; align-self: center; font-size: 0.8125rem; }
.filters__quick a[aria-current] { font-weight: 600; text-decoration: none; color: var(--text); }
.filters__clear { align-self: center; font-size: 0.8125rem; }
details.pick { position: relative; }
details.pick > summary { list-style: none; cursor: pointer; display: grid; gap: 0.2rem; font-size: 0.8rem; color: var(--muted); }
details.pick > summary::-webkit-details-marker { display: none; }
.pick__value { display: block; padding: 0.35rem 1.6rem 0.35rem 0.6rem; border: 1px solid var(--border-strong);
  border-radius: var(--radius-sm); background: var(--surface); color: var(--text);
  max-width: 14rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; position: relative; }
.pick__value::after { content: "▾"; position: absolute; right: 0.5rem; color: var(--muted); }
.pick__menu { position: absolute; z-index: 30; top: 100%; left: 0; margin-top: 0.25rem; min-width: 12rem;
  display: grid; gap: 0.15rem; padding: 0.4rem; border: 1px solid var(--border-strong);
  border-radius: var(--radius-sm); background: var(--surface); box-shadow: 0 6px 18px rgb(0 0 0 / 0.15); }
.filters .pick__item { display: flex; gap: 0.45rem; align-items: center; padding: 0.15rem 0.3rem; font-size: 0.875rem; color: var(--text); }
.pick__item input { margin: 0; }
.pick__item .status { flex: none; }
.pick__n { margin-left: auto; color: var(--muted); font-variant-numeric: tabular-nums; }
th.pick, td.pick { width: 1.5rem; padding-right: 0; }
td.pick input, th.pick input { margin: 0; vertical-align: middle; }
form.bulk { display: flex; flex-wrap: wrap; gap: 0.5rem 0.8rem; align-items: center; margin: 0 0 0.6rem; font-size: 0.875rem; }
.bulk__what, .bulk__all { color: var(--muted); }
.bulk__all { display: flex; gap: 0.35rem; align-items: center; }
form.bulk button { font-size: 0.8125rem; padding: 0.2rem 0.6rem; }
p.bulk__login { margin: 0 0 0.6rem; font-size: 0.8125rem; color: var(--muted); }
body.anon p.bulk__login { display: block; }
.notice { padding: 0.5rem 0.75rem; border: 1px solid var(--border-strong); border-left: 3px solid var(--lake);
  border-radius: var(--radius-sm); background: var(--surface); font-size: 0.875rem; }
@media (max-width: 40rem) {
  .filters { gap: 0.5rem 0.6rem; }
  .filters label, details.pick { flex: 1 1 8.5rem; }
  .filters label input, .filters label select { width: 100%; }
  .pick__value { max-width: none; }
  .filters__quick { flex-basis: 100%; }
}
.pager { display: flex; flex-wrap: wrap; gap: 0.5rem 1rem; align-items: baseline; margin-top: 0.8rem; font-size: 0.875rem; }
.pager__at { color: var(--muted); font-variant-numeric: tabular-nums; }
input, button, select { font: inherit; padding: 0.35rem 0.6rem; border: 1px solid var(--border-strong);
  border-radius: var(--radius-sm); background: var(--surface); color: var(--text); }
input:focus-visible, button:focus-visible, select:focus-visible { outline: 2px solid var(--lake);
  outline-offset: 1px; border-color: var(--lake); }
button { cursor: pointer; font-weight: 500; }
button:hover { border-color: var(--lake); color: var(--lake); }
button.danger { color: var(--bad); }
button.danger:hover { border-color: var(--bad); background: color-mix(in srgb, var(--bad) 6%, transparent); }
.actions { display: flex; flex-wrap: wrap; gap: 0.6rem 1.5rem; align-items: end; margin: 1rem 0; }
form.action { display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: end; margin: 0; }
form.action label { display: grid; gap: 0.2rem; font-size: 0.8rem; color: var(--muted); }
form.act { display: inline; margin: 0 0 0 0.4rem; }
.act__btn { font-size: 0.75rem; padding: 0.05rem 0.45rem; vertical-align: middle; font-weight: 500; }
h1 .act__btn { font-size: 0.8125rem; padding: 0.15rem 0.6rem; }
.act__login { display: none; margin-left: 0.4rem; font-size: 0.75rem; font-weight: 400; }
body.anon form.act, body.anon .act__need { display: none; }
body.anon .act__login { display: inline; }
/* The dialog an action asks with (`_ASK`): a card over the page. */
dialog.ask { width: min(28rem, calc(100vw - 2rem)); max-height: calc(100dvh - 2rem); margin: auto; padding: 0;
  background: var(--surface); color: var(--text); border: 1px solid var(--border-strong);
  border-radius: var(--radius); box-shadow: var(--shadow), 0 24px 48px -20px rgb(0 0 0 / 0.35); font: inherit; }
dialog.ask::backdrop { background: rgb(14 13 17 / 0.45); }
dialog.ask[open] { animation: ask-in 0.12s ease-out; }
@keyframes ask-in { from { opacity: 0; transform: translateY(0.4rem); } }
@media (prefers-reduced-motion: reduce) { dialog.ask[open] { animation: none; } }
.ask__form { display: grid; gap: 0.5rem; margin: 0; padding: 1.15rem 1.25rem 1.1rem; }
.ask__title { margin: 0; font-size: 1.05rem; font-weight: 600; line-height: 1.35; overflow-wrap: anywhere; }
.ask__body { margin: 0; color: var(--muted); font-size: 0.875rem; overflow-wrap: anywhere; }
.ask__body:empty { display: none; }
.ask__btns { display: flex; flex-wrap: wrap; justify-content: flex-end; gap: 0.5rem; margin-top: 0.6rem; }
dialog.ask .ask__yes { background: var(--lake); border-color: var(--lake); color: var(--bg); font-weight: 600; }
dialog.ask .ask__yes.danger { background: var(--bad); border-color: var(--bad); color: var(--bg); }
dialog.ask .ask__yes:hover { filter: brightness(1.08); color: var(--bg); }
@media (max-width: 30rem) { .ask__btns > button { flex: 1 1 auto; padding: 0.5rem 0.75rem; } }
.chain { margin: 0.4rem 0 0.8rem; padding-left: 1.4rem; }
.chain__level { margin: 0.2rem 0; }
.chain__level + .chain__level::marker { content: "→ "; }
form.start { display: grid; gap: 0.7rem; margin: 1rem 0; max-width: 46rem; }
.start__range { display: grid; gap: 0.2rem; font-size: 0.8rem; color: var(--muted); max-width: 22rem; }
.start__check { font-size: 0.875rem; display: flex; gap: 0.4rem; align-items: center; }
.start__choices { display: flex; flex-wrap: wrap; gap: 0.6rem 1.5rem; }
.start__choice { display: grid; gap: 0.25rem; max-width: 21rem; align-content: start; }
.start__choice p { margin: 0; font-size: 0.8125rem; }
form.start > button { justify-self: start; }
button.primary { background: var(--lake); border-color: var(--lake); color: #fff; font-weight: 600; }
button.primary:hover { filter: brightness(1.08); color: #fff; }
.start__preview p { margin: 0.2rem 0; }
.start__preview .refused { color: var(--bad); }
.start__cli { margin: 0; font-size: 0.8125rem; }
pre.cmd { margin: 0; background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius-sm);
  padding: 0.5rem 0.8rem; font-size: 0.8125rem; overflow-x: auto; user-select: all; }
.cmdbox { display: flex; gap: 0.5rem; align-items: stretch; }
.cmdbox pre.cmd { flex: 1; min-width: 0; }
.cmdbox .copy { flex: none; font-size: 0.8125rem; }
.auth { max-width: 22rem; margin: 3rem auto; background: var(--surface); border: 1px solid var(--border);
  border-radius: var(--radius); box-shadow: var(--shadow); padding: 1.6rem 1.75rem 1.5rem; }
.auth h1 { font-size: 1.35rem; margin: 0 0 1rem; }
.auth .error { margin: 0 0 0.8rem; font-size: 0.875rem; }
.auth .muted { font-size: 0.8125rem; margin: 1rem 0 0; }
form.login { display: grid; gap: 0.7rem; }
form.login label { display: grid; gap: 0.25rem; font-size: 0.8125rem; color: var(--muted); }
form.login input { display: block; width: 100%; }
form.login button { margin-top: 0.4rem; background: var(--ember); border-color: var(--ember);
  color: #fff; font-weight: 600; }
form.login button:hover { background: var(--ember-soft); border-color: var(--ember-soft); color: #fff; }

/* Logs and errors. */
pre.log { background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius);
  padding: 0.8rem 1rem; font-size: 0.8rem; line-height: 1.45; max-height: 70vh; overflow: auto;
  white-space: pre-wrap; }
pre.error { color: var(--bad); background: var(--surface); border: 1px solid var(--border);
  border-left: 3px solid var(--bad); border-radius: var(--radius-sm); padding: 0.6rem 0.9rem; }

/* The DAG of a pipeline's steps, coloured by a run. */
.dag { display: block; margin: 0.5rem 0 0.5rem; font-family: var(--mono); }
.dag rect { fill: var(--surface); stroke: var(--border-strong); stroke-width: 1.5; }
.dag__edge { fill: none; stroke: var(--faint); stroke-width: 1.5; }
.dag__head { fill: var(--faint); }
.dag__name { font-size: 13px; font-weight: 600; fill: var(--text); }
.dag__kind { font-size: 11px; fill: var(--muted); }
.dag a:hover rect { stroke: var(--lake); }
/* A link to source code on its host, unlike a link inside morca: an icon, the
   file and line in monospace, and an arrow out. */
a.src { font-family: var(--mono); font-size: 0.78rem; font-weight: 400; color: var(--muted);
  text-decoration: none; white-space: nowrap; }
a.src:hover { color: var(--lake); }
a.src:hover .src__at { text-decoration: underline; text-underline-offset: 0.18em; }
.src__icon { display: inline-block; vertical-align: -0.1em; margin-right: 0.3em; }
.src__out { color: var(--faint); margin-left: 0.2em; }
a.src:hover .src__out { color: inherit; }
.steps-of { color: var(--muted); }
.doc { font-size: 0.75rem; font-weight: 400; margin-left: 0.5rem; color: var(--faint); }
.dag__box--succeeded rect { stroke: var(--ok); }
.dag__box--failed rect { stroke: var(--bad); stroke-width: 2; }
.dag__box--running rect { stroke: var(--live); stroke-width: 2; }
.dag__box--skipped rect, .dag__box--pending rect, .dag__box--queued rect,
.dag__box--cancelled rect { stroke-dasharray: 4 3; }

/* The flow of datasets through pipelines. */
.graph { display: block; margin: 0.5rem auto; font-family: var(--mono); max-width: 100%; height: auto; }
.graph rect { fill: var(--surface); stroke: var(--border-strong); stroke-width: 1.5; }
.graph a:hover rect { stroke: var(--lake); }
.graph__edge { fill: none; stroke: var(--faint); stroke-width: 1.5; }
.graph__head { fill: var(--faint); }
.graph__label { font-size: 13px; font-weight: 600; fill: var(--text); }
.graph__sub { font-size: 11px; fill: var(--muted); }
.graph__node--dataset rect { stroke: var(--lake); }
.graph__node--pipeline rect { stroke: var(--ember); }
.graph__node--source rect { stroke-dasharray: 4 3; }
.graph__node--start rect { stroke: var(--ember); stroke-width: 2.5; }

/* Timelines and the runs-per-day chart. */
.tl { display: block; margin: 0.5rem 0; font-family: var(--mono); }
.tl__lane, .tl__time { font-size: 11px; fill: var(--faint); }
.tl__tick { stroke: var(--border); }
.tl__count { fill: none; stroke: var(--lake); stroke-width: 2; }
.tl--0 { fill: var(--lake); } .tl--1 { fill: var(--ember); } .tl--2 { fill: var(--ok); }
.tl--3 { fill: #7a5af8; } .tl--4 { fill: #b54708; } .tl--5 { fill: #c11574; }
.tl---1 { fill: var(--faint); }
.runs--ok { fill: var(--lake); } .runs--bad { fill: var(--bad); }
.runs--other { fill: var(--border-strong); }
.runs--none { fill: transparent; }
.tl g:hover .runs--ok { fill: var(--lake-soft); }
.tl g:hover .runs--none { fill: color-mix(in srgb, var(--text) 4%, transparent); }

/* A run's machines (morca.metrics). */
.mx__name { font-size: 12px; font-weight: 600; fill: var(--text); }
.mx__strip { fill: var(--surface-2); }
.mx__cpu { fill: color-mix(in srgb, var(--lake) 55%, transparent); }
.mx__wait { fill: color-mix(in srgb, var(--warn) 45%, transparent); }
.mx__steal, .mx__mem, .mx__disk, .mx__io, .mx__net { fill: none; stroke-width: 1.5; }
.mx__steal { stroke: var(--bad); }
.mx__mem { stroke: var(--ember); } .mx__disk { stroke: #7a5af8; }
.mx__io { stroke: #b54708; } .mx__net { stroke: var(--lake); }
.mx__warn { fill: color-mix(in srgb, var(--bad) 14%, transparent); }
.mx__now { stroke: var(--live); stroke-dasharray: 3 3; }
.mx__key { display: inline-block; width: 0.9em; height: 0.55em; margin: 0 0.3em 0 0.7em; border-radius: 2px; }
.mx__key--cpu { background: color-mix(in srgb, var(--lake) 55%, transparent); }
.mx__key--wait { background: color-mix(in srgb, var(--warn) 45%, transparent); }
.mx__key--steal { background: var(--bad); } .mx__key--mem { background: var(--ember); }
.mx__key--disk { background: #7a5af8; } .mx__key--io { background: #b54708; }
.mx__key--net { background: var(--lake); }
.mx__key--warn { background: color-mix(in srgb, var(--bad) 14%, transparent); border: 1px solid var(--bad); }
/* The fleet page (morca.fleet): summary cards, the hosts table and charts. */
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(11.5rem, 1fr)); gap: 0.75rem;
  margin: 0 0 1.25rem; }
.stat { display: grid; gap: 0.15rem; align-content: start; background: var(--surface);
  border: 1px solid var(--border); border-radius: var(--radius); box-shadow: var(--shadow);
  padding: 0.7rem 0.9rem; color: var(--text); text-decoration: none; }
.stat:hover { border-color: var(--lake); }
.stat__k { font-family: var(--mono); font-size: 0.6875rem; text-transform: uppercase;
  letter-spacing: 0.08em; color: var(--faint); }
.stat__v { font-size: 1.5rem; font-weight: 650; letter-spacing: -0.02em; line-height: 1.2;
  font-variant-numeric: tabular-nums; }
.stat__v small { font-size: 0.8125rem; font-weight: 400; color: var(--muted); }
.stat__s { font-size: 0.8125rem; color: var(--muted); }
.stat--errors .stat__v { color: var(--bad); }
.stats--compact .stat { padding: 0.45rem 0.75rem; }
.stats--compact .stat__v { font-size: 1.15rem; }
.spark { display: inline-block; vertical-align: middle; }
.spark polyline { fill: none; stroke: var(--lake); stroke-width: 1.5; stroke-linejoin: round; }
.stat--errors .spark polyline { stroke: var(--bad); }
table.hosts td, table.hosts th { vertical-align: middle; }
a.sortby { color: inherit; text-decoration: none; }
a.sortby:hover { color: var(--text); }
th[aria-sort] { color: var(--text); }
.range { margin: 1.25rem 0 0; font-size: 0.875rem; color: var(--muted); }
svg.fl { display: block; width: 100%; min-width: 34rem; height: auto; font-family: var(--mono); }
.fl--0 { fill: var(--lake); } .fl--1 { fill: var(--ember); } .fl--2 { fill: #7a5af8; }
.fl--3 { fill: #d4a72c; }
.fl--live { fill: var(--live); } .fl--bad { fill: var(--bad); } .fl--faint { fill: var(--faint); }
.fl__line { fill: none; stroke-width: 1.75; stroke-linejoin: round; }
.fl__line.fl--0 { stroke: var(--lake); } .fl__line.fl--1 { stroke: var(--ember); }
.fl__line.fl--faint { stroke: var(--faint); stroke-dasharray: 4 3; }
.fl__line.fl--2 { stroke: #7a5af8; } .fl__line.fl--live { stroke: var(--live); }
.fl__line.fl--3 { stroke: #d4a72c; }
.fl__line.fl--bad { stroke: var(--bad); }
/* A warning on the home and system pages (morca.system). */
.alert { margin: 0 0 1.25rem; padding: 0.6rem 0.9rem; border-radius: var(--radius); font-size: 0.9rem;
  color: var(--warn); background: color-mix(in srgb, var(--warn) 10%, transparent);
  border: 1px solid color-mix(in srgb, var(--warn) 35%, transparent); }
.alert a { color: inherit; font-weight: 600; }
.alert--trip { color: var(--bad); background: color-mix(in srgb, var(--bad) 10%, transparent);
  border-color: color-mix(in srgb, var(--bad) 45%, transparent); }
.fl__area { stroke: none; opacity: 0.22; }
.fl__keys { margin: 0; padding: 0.4rem 1.1rem 0.8rem; font-size: 0.8125rem; color: var(--muted); }
.fl__key { display: inline-block; width: 0.9em; height: 0.55em; margin-right: 0.3em; border-radius: 2px;
  background: currentColor; }
.fl__key.fl--0 { color: var(--lake); } .fl__key.fl--1 { color: var(--ember); }
.fl__key.fl--2 { color: #7a5af8; } .fl__key.fl--live { color: var(--live); }
.fl__key.fl--3 { color: #d4a72c; }
.fl__key.fl--bad { color: var(--bad); } .fl__key.fl--faint { color: var(--faint); }
.cal { display: grid; gap: 0.4rem; max-width: 22rem; margin: 0.3rem 0; }
.cal[hidden] { display: none; }
.cal__head { display: flex; align-items: center; justify-content: space-between; gap: 0.5rem; }
.cal__head a, .cal__head button { min-width: 2.25rem; text-align: center; padding: 0.2rem 0.5rem; }
.cal__grid { display: grid; gap: 0.2rem; list-style: none; margin: 0; padding: 0; }
.cal__grid--days { grid-template-columns: repeat(7, 1fr); }
.cal__grid--months { grid-template-columns: repeat(4, 1fr); }
.cal__dow { text-align: center; font-size: 0.7rem; color: var(--faint); }
.cal__day { display: flex; align-items: center; justify-content: center; position: relative; min-height: 2.25rem;
  font: inherit; font-size: 0.8125rem; padding: 0; border: 1px solid var(--border); border-radius: var(--radius-sm);
  background: var(--surface); color: var(--text); }
button.cal__day { cursor: pointer; }
.cal__day::after { position: absolute; top: 1px; right: 3px; font-size: 0.6rem; line-height: 1; }
.cal--done { background: color-mix(in srgb, var(--ok) 22%, var(--surface)); border-color: var(--ok); }
.cal--done::after { content: "\\2713"; color: var(--ok); }
.cal--failed { background: color-mix(in srgb, var(--bad) 22%, var(--surface)); border-color: var(--bad); }
.cal--failed::after { content: "\\2715"; color: var(--bad); }
.cal--live { background: color-mix(in srgb, var(--live) 22%, var(--surface)); border-color: var(--live); }
.cal--live::after { content: "\\25CF"; color: var(--live); }
.cal--outside { color: var(--faint); background: var(--bg-alt); border-style: dashed; opacity: 0.6; cursor: default; }
.cal--sel { outline: 2px solid var(--lake); outline-offset: -2px; font-weight: 700; }
.cal--anchor { box-shadow: 0 0 0 2px var(--ember); }
button.cal__day:focus-visible { outline: 2px solid var(--lake-soft); outline-offset: 1px; }
.cal__legend, .cal__hint { margin: 0; font-size: 0.75rem; }
.cal__key { display: inline-block; width: 0.7rem; height: 0.7rem; border-radius: 2px; vertical-align: middle; }
.cal__key::after { content: none; }
.cal--static .cal__day { cursor: default; }
/* While a Data tab loads (morca._internal.ui.loading): a bar along the top, and a note. */
body.loading { cursor: progress; }
body.loading::before { content: ""; position: fixed; top: 0; left: 0; right: 0; height: 3px; z-index: 60;
  background: linear-gradient(90deg, transparent, var(--lake), transparent) no-repeat;
  background-size: 40% 100%; animation: loading-bar 1.1s linear infinite; }
body.loading::after { content: "Loading data\2026"; position: fixed; top: 0.6rem; right: 1rem; z-index: 60;
  font-size: 0.8125rem; padding: 0.2rem 0.7rem; border-radius: 999px; color: var(--lake);
  background: var(--surface); border: 1px solid var(--border-strong); box-shadow: var(--shadow); }
@keyframes loading-bar { from { background-position: -60% 0; } to { background-position: 160% 0; } }
@media (prefers-reduced-motion: reduce) {
  body.loading::before { animation: none; background: var(--lake); } }
.sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); white-space: nowrap; }
"""
