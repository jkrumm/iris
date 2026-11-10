import {
  ArcElement,
  BarController,
  BarElement,
  CategoryScale,
  Chart,
  Filler,
  Legend,
  LineController,
  LineElement,
  LinearScale,
  PieController,
  PointElement,
  Tooltip,
  type ChartConfiguration,
} from "chart.js";
import { useEffect, useRef } from "react";
import type { Scheme } from "../payload";
import type { ChartSpec } from "../spec";
import { cssVar } from "../theme";
import { seriesColors, withAlpha } from "./colors";

Chart.register(
  BarController,
  LineController,
  PieController,
  BarElement,
  LineElement,
  PointElement,
  ArcElement,
  CategoryScale,
  LinearScale,
  Filler,
  Legend,
  Tooltip,
);

function buildConfig(spec: ChartSpec): ChartConfiguration {
  const colors = seriesColors();
  const muted = cssVar("--iris-muted", "#525255");
  const grid = cssVar("--iris-hairline", "#eaeaee");
  const panel = cssVar("--iris-panel", "#fafafd");
  const font = {
    family: cssVar("--iris-font-body", "-apple-system, system-ui, sans-serif"),
    size: 11,
  };
  const labels = spec.x.map(String);
  const pie = spec.kind === "pie";
  const unit = spec.unit ? ` ${spec.unit}` : "";

  const datasets = spec.series.map((series, index) => {
    const color = colors[index % colors.length] ?? muted;
    if (pie) {
      return {
        label: series.name,
        data: series.values,
        backgroundColor: labels.map((_, i) => colors[i % colors.length] ?? muted),
        borderColor: panel,
        borderWidth: 2,
      };
    }
    if (spec.kind === "bar") {
      return { label: series.name, data: series.values, backgroundColor: color, borderRadius: 3 };
    }
    return {
      label: series.name,
      data: series.values,
      borderColor: color,
      backgroundColor: withAlpha(color, 0.18),
      pointBackgroundColor: color,
      pointRadius: 2.5,
      borderWidth: 2,
      tension: 0.25,
      spanGaps: false,
      fill: spec.kind === "area" ? "origin" : false,
    };
  });

  return {
    type: pie ? "pie" : spec.kind === "bar" ? "bar" : "line",
    data: { labels, datasets: datasets as never },
    options: {
      animation: false,
      responsive: true,
      maintainAspectRatio: false,
      layout: { padding: 2 },
      plugins: {
        legend: {
          display: pie || spec.series.length > 1,
          position: "bottom",
          labels: { color: muted, font, boxWidth: 10, boxHeight: 10, usePointStyle: true },
        },
        tooltip: {
          callbacks: {
            label: (item) => {
              const value = item.parsed as number | { y: number };
              const number = typeof value === "number" ? value : value.y;
              return `${item.dataset.label ?? ""}: ${number}${unit}`;
            },
          },
        },
      },
      scales: pie
        ? {}
        : {
            x: {
              grid: { color: grid, display: spec.kind !== "bar" },
              ticks: { color: muted, font },
              border: { color: grid },
            },
            y: {
              grid: { color: grid },
              border: { display: false },
              ticks: { color: muted, font },
              title: { display: Boolean(spec.unit), text: spec.unit ?? "", color: muted, font },
            },
          },
    },
  };
}

/** `scheme` is a dependency only: a change rebuilds the chart so it reads the new token colors. */
export function ChartView({ spec, scheme }: { spec: ChartSpec; scheme: Scheme }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    if (!canvas.current) return;
    const chart = new Chart(canvas.current, buildConfig(spec));
    return () => chart.destroy();
    // `scheme` is not read inside: a change rebuilds the chart so it re-reads the token colors.
    // oxlint-disable-next-line react/exhaustive-effect-dependencies
  }, [spec, scheme]);
  return (
    <div className="chart">
      <canvas ref={canvas} role="img" aria-label={spec.title ?? spec.series[0]?.name} />
    </div>
  );
}
