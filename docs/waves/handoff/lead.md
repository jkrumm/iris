# Lead handoff — Wave 21 (lead `iris-w21-lead`, active)

## State (2026-11-04 23:30)
- **H1 + H1b done, live:** hermes-agent `4a95400..fa8e444` (skill `iris`, block `{kind, headline}`, agent work via `factory issue new`),
  `agw review` clean on both ranges.
- **S1 done, deployed:** #120 (superseded #119) merged as `4818ab9`, deployed, `make verify` healthy, `make smoke` notified with `kind: chat`, summary
  from `triage`; DB `user_version` 14. Migration 14 turned **16 open `needs_route` memos into `failed(act)`**: Retry from Act would hand them to
  Hermes, which may act on them (tasks, notes): the owner's call, the lead does not retry them.
- **P1** #121 (pane t12k): code done, paid device build + install + APNs registration worked pre-rebase (`devices.iphone` has a sandbox token;
  a typed memo `a2855744` notified with no `no_token` / rejection). **Owner step:** App Group `group.com.jkrumm.iris` in the developer portal on
  the three App IDs (until then device builds need `DEVICE_DROP_ENTITLEMENTS=com.apple.security.application-groups`). After 07:00: re-run
  `PushRegistrarTests`, `make check-apple`, `make device` on the rebased head, banner screenshot, Live Activity `end` push.
- **A1** #122 (pane t12g): three-button row, Transcribe control, Mac pair, routing UI removed, written but **never compiled** (load stop). After
  07:00: rebase on master, validation, row renders into `docs/design/fidelity/w21.md`.
- **Load stop (owner-approved, software-factory session):** no xcodebuild / simulator until 2026-11-05 07:00.
- Then: A1 + P1 batch (`w21-batch-1`), one `apple.yml`, `agw review` on both, merge, close out.
