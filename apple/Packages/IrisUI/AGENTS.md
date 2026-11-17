# IrisUI (Theme, components, conversation and artifact views)

Design is `docs/TDD.md` §4 (Screens, Thread view, Prose renderer, Artifacts in the conversation). Screen mockups and per-screen deltas: `docs/design/mockups/` and `docs/design/fidelity/`. How the thread view, reply rendering, artifacts and Live Activity views fit together: `docs/apple-app.md`; read it before changing `Components/` conversation or artifact code.

## Theme

- No spacing literals in views. Every padding, stack or grid spacing and inset is a step or role of `Theme.Spacing` (`Theme/Spacing.swift`: `hair…xl`, `screenMargin`, `sectionTop`, `rowVertical`, `chipGap`, `barInset`, `menu*`, `mac*`), derived from `docs/design/mockups/*.css`. A value the scale lacks is added there with the mockup it comes from, never typed in a view. Control sizes (a 44 pt button, a 3 pt dash) are not spacing.
- `BasaltTokens.generated.swift` comes from the pinned basalt-ui tokens: `make theme` regenerates it and `make check-apple` fails on drift. Never edit it.
- `Theme/CodeColors.swift` is hand-written (JetBrains Light and Dark colors), because basalt-ui has no syntax tokens. Textual tokenizes after the first frame, so snapshots show no token colors.
- Textual is pinned `exact: 0.5.0` in `IrisUI` only; no other package imports it.
- No screen draws a title block: the tab bar says where you are and content starts under the status-bar scrim.

## Conversation and artifacts

- Reply markdown renders through `MessageContentView`; `MessageBlock.split` numbers Mermaid and artifact fences the way the server's `ReplyBlock.index` and `ReplyArtifact.index` do, so keep the two counts in step.
- An artifact is one sandboxed `WebView` (`ArtifactWebView`). Content comes only from the custom scheme `iris-artifact://` (`ArtifactSchemeHandler`) under a CSP: bundled pages get own-scheme script and style with `connect-src` none, an HTML document is its own inline page with styles and no script and never loads the bundled renderer. `ArtifactNavigationPolicy` lets http(s), mailto and tel links leave through `openURL` and cancels every other navigation.
- At most three islands are live per conversation (`ArtifactIslandBudget`); the rest are snapshots. A failed or refused artifact falls back to its fence as code with a retry.
- The host's bridge is the message handler `iris` in the isolated content world `iris-bridge` (theme variables, ResizeObserver height, `ready`); the page carries none (`web/AGENTS.md`). `ArtifactTheme` sets the `--iris-*` variables, and a test compares its key set with `web/src/dev/theme.ts`.
- Authenticated media (audio, speech, Mermaid PNGs, artifact files) is downloaded with the bearer header through `MediaDownloader` and played from the file: never `AVURLAssetHTTPHeaderFieldsKey`, and the WebView loads nothing from the network.
- `SpeechPlayer` is the one spoken-reply player (`Memo.isSpeakable` is the one rule). It never interrupts: a playback start reads `captureActive` at the moment it starts, a take start pauses playback, and nothing resumes by itself. The reply plays as `variant=summary` or `variant=full` (`ReplyPlayButton`'s menu, under every finished answer in `ConversationTurnList` via `ReplyControls`, and in the Details sheet); the auto-read and `PlayReplyIntent` send no variant and get the server default. Another form of the memo that speaks restarts it, the same form pauses.
- Money is formatted by `StepText.dollars` (locale, no fixed `$`, four decimals below a cent), never inline.
- Debug launch arguments for artifact screens (`-IrisArtifactSample`, `-IrisArtifactIslands`) and the Mac snapshot run are listed in `docs/apple-app.md`.
