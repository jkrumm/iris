import IrisCore
import SwiftUI

/// The speaker: one compact icon, no chevron segment. Idle it is a menu (the summary first, then the whole reply); while the reply
/// reads it is a Stop button, so what reads can always be stopped in one click. It is the only control in the toolbar that reads the
/// reply: the user's own recording is ``MacRecordingButton``.
struct MacSpeakerMenu: View {
  let root: MacCompositionRoot
  let player: MacAudioPlayer
  let memo: Memo

  var body: some View {
    if root.mediaSource.speech(for: memo, variant: .summary) != nil {
      if player.isReplyCurrent(memo.id) {
        Button {
          player.stop()
        } label: {
          Label(
            String(localized: "Stop reply", comment: "Detail toolbar: stops the spoken reply"),
            systemImage: "stop.circle.fill")
        }
        .macToolbarInk()
        .help(MacMemoControl.stopReply.help)
        .accessibilityIdentifier("mac.detail.play-reply")
      } else {
        Menu {
          MacSpeakerEntries { readAloud($0) }
        } label: {
          Label(
            String(localized: "Read reply aloud", comment: "Detail toolbar: speaks the reply"),
            systemImage: "speaker.wave.2")
        }
        .menuIndicator(.hidden)
        .macToolbarInk()
        .help(MacMemoControl.readReply.help)
        .accessibilityIdentifier("mac.detail.play-reply")
      }
    }
  }

  private func readAloud(_ variant: SpeechVariant) {
    player.toggle(memo.id, .reply(variant), request: root.mediaSource.speech(for: memo, variant: variant))
  }
}

/// The entries of the speaker's menu: the summary first, then the whole reply. The toolbar and the snapshot proof draw the same ones.
struct MacSpeakerEntries: View {
  let onRead: (SpeechVariant) -> Void

  var body: some View {
    entry(
      .summary, title: String(localized: "Read the summary", comment: "Speaker menu: the short spoken form"),
      icon: "text.quote", help: .readSummary)
    entry(
      .full, title: String(localized: "Read the full reply", comment: "Speaker menu: the whole reply spoken"),
      icon: "text.alignleft", help: .readFull)
  }

  private func entry(_ variant: SpeechVariant, title: String, icon: String, help: MacMemoControl) -> some View {
    Button(title, systemImage: icon) { onRead(variant) }
      .help(help.help)
      .accessibilityIdentifier("mac.detail.play-reply.\(variant.rawValue)")
  }
}

/// The user's own recording, a direct button with the waveform glyph (the speaker is a speaker): it plays what was said, not the
/// reply, so the two are never mistaken for each other.
struct MacRecordingButton: View {
  let root: MacCompositionRoot
  let player: MacAudioPlayer
  let memo: Memo

  var body: some View {
    if let request = root.mediaSource.audio(for: memo) {
      let playing = player.isCurrent(memo.id, .recording)
      Button {
        player.toggle(memo.id, .recording, request: request)
      } label: {
        Label(
          playing
            ? String(localized: "Stop recording", comment: "Detail toolbar: stops the recording")
            : String(localized: "Play recording", comment: "Detail toolbar: plays the recording"),
          systemImage: playing ? "stop.fill" : "waveform")
      }
      .macToolbarInk()
      .help((playing ? MacMemoControl.stopRecording : .playRecording).help)
      .accessibilityIdentifier("mac.detail.play-recording")
    }
  }
}
