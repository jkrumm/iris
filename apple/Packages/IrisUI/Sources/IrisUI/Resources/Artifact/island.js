(() => {
  const SVG = "http://www.w3.org/2000/svg";
  const root = document.getElementById("root");

  const el = (tag, props = {}, children = []) => {
    const node = document.createElement(tag);
    Object.assign(node, props);
    node.append(...children);
    return node;
  };

  const deltaClass = (delta) => (delta.startsWith("-") ? "good" : delta.startsWith("+") ? "bad" : "");

  const chart = (bars) => {
    const svg = document.createElementNS(SVG, "svg");
    svg.setAttribute("viewBox", "0 0 100 40");
    svg.setAttribute("preserveAspectRatio", "none");
    const max = Math.max(...bars, 1);
    const slot = 100 / bars.length;
    bars.forEach((value, index) => {
      const h = (value / max) * 38;
      const rect = document.createElementNS(SVG, "rect");
      rect.setAttribute("x", String(index * slot + slot * 0.15));
      rect.setAttribute("y", String(40 - h));
      rect.setAttribute("width", String(slot * 0.7));
      rect.setAttribute("height", String(h));
      svg.append(rect);
    });
    return svg;
  };

  // Proves the CSP: a fetch to the network must be rejected.
  const probeNetwork = (target) => {
    fetch("https://example.com/").then(
      () => { target.textContent = "network: OPEN"; },
      () => { target.textContent = "network: blocked"; },
    );
  };

  window.iris = {
    render(payload) {
      const data = payload || { title: "", stats: [], bars: [] };
      const net = el("p", { id: "net", textContent: "network: checking" });
      const nav = el("button", { id: "nav", type: "button", textContent: "Navigate" });
      nav.addEventListener("click", () => { location.href = "https://example.com/"; });
      root.replaceChildren(
        el("h1", { id: "title", textContent: data.title }),
        el("div", { className: "tiles" }, (data.stats || []).map((stat) =>
          el("div", { className: "tile" }, [
            el("div", { className: "name", textContent: stat.name }),
            el("div", { className: "value", textContent: stat.value }),
            el("div", { className: "delta " + deltaClass(stat.delta), textContent: stat.delta }),
          ]))),
        chart(data.bars || []),
        net,
        el("p", {}, [el("a", { id: "ext", href: "https://example.com/docs", textContent: "Docs" }), " ", nav]),
      );
      probeNetwork(net);
    },
  };
})();
