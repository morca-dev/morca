"""What a page shows while a Data tab loads (#478): reading a table can
take seconds, so a click on a link to one (`?tab=data`, on a dataset's or
a pipeline's page) or a submit of one of its forms marks the page busy at
once: a bar along the top and "Loading data…" (`body.loading` in
`morca._internal.ui.style`). Without JavaScript the links and forms work
as they do anyway, with only the browser's own indicator."""

comptime LOADING_JS = """
(() => {
  const data = (href) => {
    try {
      const u = new URL(href, location.href);
      return u.origin === location.origin && u.searchParams.get("tab") === "data"
        && /^\\/(datasets|pipelines)\\/[^/]+$/.test(u.pathname);
    } catch (e) { return false; }
  };
  const busy = (on) => {
    document.body.classList.toggle("loading", on);
    if (on) document.body.setAttribute("aria-busy", "true");
    else document.body.removeAttribute("aria-busy");
  };
  document.addEventListener("click", (e) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    const a = e.target.closest && e.target.closest("a[href]");
    if (a && !a.target && !a.hasAttribute("download") && data(a.href)) busy(true);
  });
  document.addEventListener("submit", (e) => {
    const f = e.target;
    if (e.defaultPrevented || (f.method || "get").toLowerCase() !== "get") return;
    const tab = f.querySelector("input[name=tab]");
    if (tab && tab.value === "data") busy(true);
  });
  // Back to a page the browser kept: it's not loading any more.
  window.addEventListener("pageshow", () => busy(false));
})();
"""
