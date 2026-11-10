// DEV ONLY. Mirrors what the host emits (apple/Packages/IrisUI/Sources/IrisUI/Components/Artifact/ArtifactTheme.swift),
// with the resolved values of BasaltTokens.generated.swift (basalt-ui 2.29.0). The real host sets these on <html> itself and
// never sends `vars`; the harness and the tests do. theme.test.ts fails when the key set drifts from ArtifactTheme.swift.
import type { Scheme, Theme } from "../payload";

const light = {
  "--iris-bg": "rgb(242, 242, 245)",
  "--iris-panel": "rgb(250, 250, 253)",
  "--iris-elevated": "rgb(255, 255, 255)",
  "--iris-subtle": "rgb(244, 244, 248)",
  "--iris-border": "rgb(226, 226, 229)",
  "--iris-hairline": "rgb(234, 234, 238)",
  "--iris-divider": "rgba(38, 38, 41, 0.09)",
  "--iris-ink": "rgb(38, 38, 41)",
  "--iris-ink-2": "rgb(64, 64, 67)",
  "--iris-muted": "rgb(82, 82, 85)",
  "--iris-faint": "rgb(105, 105, 108)",
  "--iris-accent": "rgb(67, 116, 166)",
  "--iris-accent-fill": "rgb(67, 116, 166)",
  "--iris-on-accent": "rgb(255, 255, 255)",
  "--iris-status-excellent": "rgb(41, 166, 52)",
  "--iris-status-good": "rgb(47, 119, 75)",
  "--iris-status-warn": "rgb(147, 95, 0)",
  "--iris-status-bad": "rgb(181, 64, 61)",
  "--iris-status-neutral": "rgb(113, 113, 122)",
};

const dark: typeof light = {
  "--iris-bg": "rgb(39, 39, 42)",
  "--iris-panel": "rgb(43, 43, 46)",
  "--iris-elevated": "rgb(56, 56, 59)",
  "--iris-subtle": "rgb(50, 50, 53)",
  "--iris-border": "rgb(68, 68, 71)",
  "--iris-hairline": "rgb(78, 78, 81)",
  "--iris-divider": "rgba(255, 255, 255, 0.08)",
  "--iris-ink": "rgb(229, 229, 233)",
  "--iris-ink-2": "rgb(221, 221, 225)",
  "--iris-muted": "rgb(212, 212, 216)",
  "--iris-faint": "rgb(167, 167, 170)",
  "--iris-accent": "rgb(162, 195, 240)",
  "--iris-accent-fill": "rgb(67, 116, 166)",
  "--iris-on-accent": "rgb(255, 255, 255)",
  "--iris-status-excellent": "rgb(67, 191, 77)",
  "--iris-status-good": "rgb(82, 192, 124)",
  "--iris-status-warn": "rgb(230, 165, 61)",
  "--iris-status-bad": "rgb(254, 129, 120)",
  "--iris-status-neutral": "rgb(161, 161, 170)",
};

const shared = {
  "--iris-radius-card": "10px",
  "--iris-radius-ctrl": "6px",
  "--iris-radius-tight": "5px",
  "--iris-radius-fine": "4px",
  "--iris-radius-floating": "11px",
  "--iris-space-xs": "4px",
  "--iris-space-sm": "8px",
  "--iris-space-md": "12px",
  "--iris-space-lg": "16px",
  "--iris-space-xl": "24px",
  "--iris-text-nano": "10px",
  "--iris-text-micro": "11px",
  "--iris-text-xs": "12px",
  "--iris-text-sm": "13px",
  "--iris-text-md": "15px",
  "--iris-text-lg": "16px",
  "--iris-text-xl": "18px",
  "--iris-text-h2": "21px",
  "--iris-text-kpi": "22px",
  "--iris-text-h1": "26px",
  "--iris-text-display": "30px",
  "--iris-font-body": "-apple-system, system-ui, sans-serif",
  "--iris-font-mono": "ui-monospace, SFMono-Regular, Menlo, monospace",
};

export const devVars = (scheme: Scheme): Record<string, string> => ({
  ...(scheme === "dark" ? dark : light),
  ...shared,
});

export const devTheme = (scheme: Scheme): Theme => ({ scheme, vars: devVars(scheme) });
