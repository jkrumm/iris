# S3: APNs Live Activity update and [Play] from a suspended app

**Question.** With the app suspended, does an APNs push update the Live Activity (phase `done`, headline), and does a [Play] button on it (or on the
notification) start `/speech` playback? (TDD §4 Live Activity, Notifications; §13.)

**Prerequisites.** S1's Live Activity, `devices/register` and `memos/:id/activity-token` wired in the client, an APNs key (`APNS_KEY_P8`, `APNS_KEY_ID`,
`APNS_TEAM_ID`, `APNS_TOPIC` from 1Password, never in the repo) set in the mini's server env, the device token registered with the right `apnsEnv`
(a development build uses the sandbox host). The server-side senders are tested only against a local HTTP/2 server; this spike is their first
contact with Apple.

**Procedure.**
1. Start a take, stop it, suspend the app (home screen, lock). Let the memo run to `notified`.
2. Watch the Lock Screen: does the Live Activity move to `done` with the headline, and does the alert arrive? Check the server logs
   (`make logs`, `notify.apns_rejected`) and HyperDX for the `notify` span.
3. Press [Play]: record whether audio starts with the app suspended or the app opens (`PlayReplyIntent`).
4. Repeat with a push of `event: update` at priority 5 versus 10 and note delivery latency.

**Decide.** Pass: the update and the playback work suspended. Fail: [Play] opens the app (the accepted fallback); note any APNs status other than
200 with its reason, and fix the server payload through `server/src/notify/payloads.ts` with a contract fixture.

**Evidence.** Device model, iOS version, timestamps, the APNs response status and `apns-id`, a screen recording.

## Findings
_Not run._
