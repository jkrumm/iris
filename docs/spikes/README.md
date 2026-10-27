# Spikes

Three questions that only a real phone can answer; the fleet (Fleet backlog item 1) runs them with the owner. Each brief is self-contained.
A finished spike appends **Findings** (what happened, with the device model, iOS version, date and evidence paths) to its file and amends
`docs/TDD.md` §4 and §13 in the same commit. Nothing here is built on the assumption that a spike passes.

| Spike | Question | Brief |
|-|-|-|
| S1 | Does a Lock Screen control start a take with a Live Activity, and survive 30 minutes? | `S1-lock-screen-start.md` |
| S2 | Does a mic switch mid-take work, including the built-in mic in the car? | `S2-mic-switch.md` |
| S3 | Do APNs Live Activity updates and [Play] work from a suspended app? | `S3-apns-live-activity.md` |

Prerequisites for all three: a paired iPhone with Developer Mode on, a signing team (a free team plus `devicectl` until the paid
enrolment completes), Xcode 27.1 on the mini, and for S3 an APNs key (`APNS_*`, from 1Password) in the server's env.
Run order: S1, S2, S3 (S3 needs the Live Activity from S1).
