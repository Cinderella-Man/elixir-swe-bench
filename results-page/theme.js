/* Dark unless the reader chose light on an earlier visit. Loaded before the page is drawn, so the choice never flashes. */
(() => {
  let theme = "dark";
  try { if (localStorage.getItem("theme") === "light") theme = "light"; } catch { /* no storage: the default */ }
  document.documentElement.dataset.theme = theme;
})();
