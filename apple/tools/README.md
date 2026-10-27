# apple/tools

## gen-theme.ts

Generates `Packages/IrisUI/Sources/IrisUI/Theme/BasaltTokens.generated.swift` from the pinned
`basalt-ui` release (exact version in `package.json`, locked in `bun.lock`).

```bash
cd apple/tools && bun install --frozen-lockfile && bun gen-theme.ts          # regenerate
cd apple/tools && bun install --frozen-lockfile && bun gen-theme.ts --check  # CI gate: exit 1 on drift
```

- **Install approach:** `basalt-ui` declares React, Mantine and many more as peer dependencies, and bun installs
  peers by default (70 MB). `bunfig.toml` sets `[install] peer = false`, so only `basalt-ui` itself lands in
  `node_modules` (12 MB, ~1 s). The script imports only `basalt-ui/tokens`, which is Mantine and React free.
- **Source of values:** the script reads `buildPaletteCss()` (public API) with a `data-theme` scheme selector and
  parses the light and dark `--vx-*` blocks, so the Swift tokens match what the web renders. Hex and `rgb()` values
  are converted to sRGB components; any other color format fails the run instead of being guessed.
- **Bumping basalt-ui:** change the version in `package.json`, `bun install`, `bun gen-theme.ts`, commit the lockfile
  and the regenerated Swift file together.
