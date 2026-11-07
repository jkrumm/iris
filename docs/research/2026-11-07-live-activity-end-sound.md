# Live Activity `end` push: does its alert sound play? (Issue 223)

Researched 2026-11-07 (`agw research`, standard). No iOS 26-specific statement exists; the developer reports are 2023 to 2025.

## Finding

Apple documents an `alert` with a `sound` for the `update` event (the page's example: `"sound": "HeroDown.mp4"`) and for push-to-start (`chime.aiff`). The `end`
section says only to include the final `content-state`; it never says an `end` alert plays a sound. The local API agrees: `Activity.update(_:alertConfiguration:)`
takes an `AlertConfiguration` (its `sound` is "the sound the system plays when the Live Activity alert appears"), `Activity.end(_:dismissalPolicy:)` takes none.
An Apple Developer Forums thread (October 2025, "Can you include an `alert` with a sound within the `end` event?") reports the same symptom: a sound on an
`end` event "doesn't seem to work", the activity ends without sound. The thread's replies could not be read.

The payload as sent (`server/src/notify/payloads.ts`, `buildLiveActivityEnd`) is what Apple documents for the headers: `apns-push-type: liveactivity`,
`apns-topic: <bundle>.push-type.liveactivity`, `apns-priority: 10` (the alert-appropriate value), `event: end`, final `content-state`, `alert.sound: "default"`
(no file needed), no `content-available` (it must not accompany an alert). `relevance-score` and `stale-date` do not affect sound.

Most likely cause of D1-7: the platform plays no sound for an `end` alert. Unproven, because the only proof is the device. Not ruled out from the
documentation: Focus, a Watch taking the alert while the iPhone is locked, and a `dismissal-date` close to now (ours is 15 minutes out). The owner heard the next
typed memo's alert push on the same phone, so volume and the silent switch are not the cause.

The server never logged a delivered push. Since Issue 223 `notify.apns_sent` records every accepted push: `kind`, `push_type`, `priority`, `environment`, `event`,
`alert_present`, `sound`, `status` (never the text), so the next device run has server proof of exactly what was sent.

## Sources

- Starting and updating Live Activities with ActivityKit push notifications: https://developer.apple.com/documentation/activitykit/starting-and-updating-live-activities-with-activitykit-push-notifications
- `Activity.end(_:dismissalPolicy:)`: https://developer.apple.com/documentation/activitykit/activity/end(_:dismissalpolicy:)
- `AlertConfiguration.sound`: https://developer.apple.com/documentation/activitykit/alertconfiguration/sound
- Generating a remote notification (sound, `content-available`): https://developer.apple.com/documentation/usernotifications/generating-a-remote-notification
- Sending notification requests to APNs (priority): https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns
- Live Activities HIG: https://developer.apple.com/design/human-interface-guidelines/live-activities
- Notifications on iPhone and Apple Watch (Focus, silent, Watch routing): https://support.apple.com/en-us/108274
- ActivityKit forum listing with the October 2025 `end`-sound thread: https://developer.apple.com/forums/tags/activitykit?page=4&sortBy=lastUpdated&sortOrder=DESC
