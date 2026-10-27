// Mockup runtime: scheme + variant from the query string, icon sprite, seeded waveforms.
//   ?scheme=dark|light   ?v=<variant>   (elements with data-v="a b" show only when v matches)
(() => {
  const q = new URLSearchParams(location.search);
  const scheme = q.get("scheme") ?? "light";
  const v = q.get("v") ?? document.documentElement.dataset.defaultV ?? "";
  document.documentElement.dataset.scheme = scheme;
  document.documentElement.dataset.v = v;

  const P = {
    mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5 11a7 7 0 0 0 14 0M12 18v3"/>',
    wave: '<path d="M4 10v4M8 6v12M12 3v18M16 7v10M20 10v4"/>',
    play: '<path d="M8 5.5v13l11-6.5z"/>',
    stop: '<rect x="6" y="6" width="12" height="12" rx="2.5"/>',
    pause: '<rect x="6.5" y="5" width="4" height="14" rx="1.2"/><rect x="13.5" y="5" width="4" height="14" rx="1.2"/>',
    check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
    chev: '<path d="M9 5l7 7-7 7"/>',
    back: '<path d="M15 5l-7 7 7 7"/>',
    down: '<path d="M6 9l6 6 6-6"/>',
    search: '<circle cx="11" cy="11" r="6.5"/><path d="M16 16l4.5 4.5"/>',
    clock: '<circle cx="12" cy="12" r="8.5"/><path d="M12 7v5l3 2"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M12 3v2.5M12 18.5V21M3 12h2.5M18.5 12H21M5.6 5.6l1.8 1.8M16.6 16.6l1.8 1.8M5.6 18.4l1.8-1.8M16.6 7.4l1.8-1.8"/>',
    bubble: '<path d="M5 6.5A2.5 2.5 0 0 1 7.5 4h9A2.5 2.5 0 0 1 19 6.5v6a2.5 2.5 0 0 1-2.5 2.5H11l-4 4v-4H7.5A2.5 2.5 0 0 1 5 12.5z"/>',
    book: '<path d="M5 5.5A1.5 1.5 0 0 1 6.5 4H19v15H6.5A1.5 1.5 0 0 0 5 20.5zM5 20.5V5.5"/>',
    term: '<rect x="3.5" y="5" width="17" height="14" rx="2.5"/><path d="M7.5 10l3 2.5-3 2.5M13 15h3.5"/>',
    retry: '<path d="M4.5 12a7.5 7.5 0 1 0 2.4-5.5M4.5 4.5v4h4"/>',
    warn: '<path d="M12 4l9 16H3zM12 10v4.5M12 17.5v.1"/>',
    x: '<path d="M6 6l12 12M18 6L6 18"/>',
    car: '<path d="M5 15v-3.5L7 7h10l2 4.5V15M5 15v3h2.5v-2h9v2H19v-3M5 15h14"/><circle cx="8" cy="13" r=".6"/><circle cx="16" cy="13" r=".6"/>',
    pods: '<path d="M8 4a3 3 0 0 0-3 3v3a3 3 0 0 0 3 3h.5v6.5a1 1 0 0 0 2 0V4zM16 4a3 3 0 0 1 3 3v3a3 3 0 0 1-3 3h-.5v6.5a1 1 0 0 1-2 0V4z"/>',
    phone: '<rect x="7" y="3" width="10" height="18" rx="2.5"/><path d="M11 18h2"/>',
    laptop: '<rect x="5" y="5.5" width="14" height="10" rx="1.5"/><path d="M3 18.5h18"/>',
    reply: '<path d="M10 7L4.5 12 10 17M5 12h9a5.5 5.5 0 0 1 5.5 5.5"/>',
    open: '<path d="M14 4h6v6M20 4l-9 9M18 14v4.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6H10"/>',
    flash: '<path d="M8 3h8l-2 7h3l-7 11 1.5-8H8z"/>',
    spark: '<path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z"/>',
    list: '<path d="M8 6.5h12M8 12h12M8 17.5h12M4 6.5h.1M4 12h.1M4 17.5h.1"/>',
    sig: '<path d="M3 17h2v3H3zM7.5 13h2v7h-2zM12 9h2v11h-2zM16.5 5h2v15h-2z" stroke="none" fill="currentColor"/>',
  };
  const icon = (n) => `<svg viewBox="0 0 24 24">${P[n] ?? ""}</svg>`;
  const hydrate = (root) => root.querySelectorAll("i[data-i]:not([data-done])").forEach((el) => {
    el.innerHTML = icon(el.dataset.i);
    el.dataset.done = "1";
  });

  // Seeded PRNG so waveforms are identical in every render.
  const rng = (seed) => () => ((seed = (seed * 1664525 + 1013904223) >>> 0) / 2 ** 32);
  const waves = (root) => root.querySelectorAll(".wave[data-bars]").forEach((el) => {
    if (el.dataset.done) return;
    const n = +el.dataset.bars, max = +(el.dataset.h ?? 40), r = rng(+(el.dataset.seed ?? 7));
    const live = el.hasAttribute("data-live");
    el.innerHTML = Array.from({ length: n }, (_, i) => {
      const env = 0.35 + 0.65 * Math.sin((i / n) * Math.PI);
      const h = Math.max(4, Math.round(max * (0.15 + 0.85 * r()) * (live ? 0.4 + 0.6 * env : 1)));
      return `<b style="height:${h}px"></b>`;
    }).join("");
    el.dataset.done = "1";
  });

  const apply = () => {
    document.querySelectorAll("[data-v]").forEach((el) => {
      if (el === document.documentElement) return;
      const ok = el.dataset.v.split(/\s+/).includes(v) || el.dataset.v === "*";
      el.toggleAttribute("data-hide", !ok);
    });
    hydrate(document); waves(document);
  };
  document.addEventListener("DOMContentLoaded", apply);
  window.__ready = () => document.fonts.ready.then(() => true);
})();
