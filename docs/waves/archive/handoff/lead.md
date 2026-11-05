# Lead handoff — Waves 21 and 22 closed (lead `iris-w21-lead`, ended 2026-11-05)

No successor lead or mother: iris work continues as software-factory Issues. Plan history: `docs/waves/archive/PLAN.md`.

## Shipped 2026-11-05
- Wave 21: batch #126 (`ce920c7`, A1 #122 + P1 #121), deployed, `make verify` healthy, `make smoke` notified (`kind: chat`).
- Wave 22: P2 #123 (`4ce8567`), U1 #124 (`955acd9`), M2 #125 (`3ff181c`); hosted `apple.yml` green on every head, in-session `/review` clean.
- Issue 75 (Live Activity end only, no second banner) and Issue 77 / #127 (App Group on paid device builds) by factory leads.

## Open Issues
| Id | What | Waits on |
|-|-|-|
| 77 | App Group on device builds: done, ship held | deep review cap reset (UTC midnight), then coverage of `ce920c7`, `955acd9`, `3ff181c` |
| 86 | machine budget: Apple builds/tests in `factory slot run`, simulators shut down, runners capped | - |
| 87 | three flaky UI tests, proven by hosted CI | 86 |
| 88 | first TestFlight upload, production APNs env | owner: App Store Connect app record + go |
| 89 | D1 hardware batch on the TestFlight build | 88, owner hands-on session |
| 90 | first Developer ID Mac release with Sparkle, MacBook proof | owner: go to publish |

## Owner items (not Issues)
- App Store Connect: the app record for `com.jkrumm.iris` and an internal TestFlight group, when he wants TestFlight (Issue 88 asks).
- Say go for the first GitHub Mac release (Issue 90 asks); then the MacBook rows with the lead.
- Confirm the Sparkle EdDSA private key and the Developer ID `.p12` are in 1Password; Issue 90 then deletes
  `~/.local/state/apple-developer/sparkle-ed25519.key` from the mini.
- The 16 `failed(act)` memos from migration 14 stay (owner 2026-11-05).
- Fleet backlog 10: the one B2 image object only the owner can delete.

## Mini facts worth keeping
- Developer ID signing keychain `~/Library/Keychains/iris-signing.keychain-db`, password in `~/.local/state/apple-developer/signing-keychain.pass`
  (0600); unlock it after a reboot before `make mac-release`.
- Release hooks in the poller stay off until `~/.iris/release.env` sets `TESTFLIGHT=1` / `MAC_RELEASE=1`.
- Hidden deep reviews gave up four times on 2026-11-05 (rv_4szp, rv_4jmu, rv_tsrh, rv_mde4); software-factory Issue 67 fixed it. Today's
  reviews ran in-session.
