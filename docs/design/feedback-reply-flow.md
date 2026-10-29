# Owner feedback — iPhone reply flow (Wave 15 I5 renders)

Given 2026-10-29 on the ten simulator renders listed in `docs/design/README.md` ("Reply flow as built"). Binding, on top of
`feedback-round-2.md`. Overall: **on a good trajectory**; the Liquid Glass approach stays.

- **Reply bar in one row, icons only:** keyboard on the left, **hold to talk** in the middle as an icon (no text), and on the right a
  **continuous (locked) recording** button whose icon reads as "recording, locked" (e.g. SF Symbols layered or composed: mic + lock,
  in the spirit of messaging apps' lock-to-record). Pick symbols that exist; compose them if no single one fits.
- **Thread rendering more structured:** the thread (the transcript said "failed thread"; read as the thread view's conversation) could be
  rendered and laid out with more structure: clearer separation and hierarchy between turns and inside an answer.
- **Syntax highlighting colours:** the current palette is disliked. Use JetBrains-style colours (Darcula / Dracula family). Check the
  owner's Zed configuration (theme and syntax overrides) and what basalt-ui configures for code, and derive one light and one dark theme.
- **Composer:** Cancel and Send at the top are fine, keep them. Make sure the layout holds with the keyboard up.
- **Kept as they are:** the step-progress dashes in the pending bubble, the reveal, the reply-by-text composer bound to the thread.
- **Fakes for UI work are right:** keep building and reviewing screens on the fake stack, so no AI tokens are spent on interactions.
