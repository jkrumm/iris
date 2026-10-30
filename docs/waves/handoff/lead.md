# Lead handoff — Wave 18

State as of 2026-10-30 ~20:50. PLAN.md is the plan; this file is the lead's working memory.

- Owner asks via `ask-human.sh` (MacBook unreachable at 20:40, requests pending): D3 enrolment `20261030T203639-25481`, D1 "ready for the
  re-test?" `20261030T204053-5700`. D1 starts only when the owner answers ready (reuse `w17-d2r-device-retest`); D2/D3 only if enrolment cleared.
- Fanned 20:45 (briefs `/tmp/iris-w18/*.md`, branches `w18-*`): S1 server debt, C1 toast flake, M1 Mac menu-bar, I1 reply pause + late tail,
  I23 capture recovery + debt (I2+I3), I4 UI debt. M2 (Mac capture) after M1 merges. One xcodebuild at a time (`lockf /tmp/iris-apple.lock`).
- Train: review each PR with `agw review --pr`, server PRs merge alone then deploy + `make verify` + `make smoke`; Apple PRs ride `w18-batch-N`.
