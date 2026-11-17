import IrisCore
import SwiftUI

/// The speaker: a click reads the summary (or stops what is reading), its menu offers the summary and the whole reply. It is the
/// only audio control in the toolbar's first row: the user's own recording lives in ``MacMoreMenu``.
struct MacSpeakerMenu: View {
  let root: MacCompositionRoot
  let player: MacAudioPlayer
  let memo: Memo

  var body: some View {
    if root.mediaSource.speech(for: memo, variant: .summary) != nil {
      let reading = player.isReplyCurrent(memo.id)
      Menu {
        MacSpeakerEntries { readAloud($0) }
      } label: {
        Label(
          reading
            ? String(localized: "Stop reply", comment: "Detail toolbar: stops the spoken reply")
            : String(localized: "Read reply aloud", comment: "Detail toolbar: speaks the reply"),
          systemImage: reading ? "stop.circle.fill" : "speaker.wave.2")
      } primaryAction: {
        if reading {
          player.stop()
        } else {
          readAloud(.summary)
        }
      }
      .help((reading ? MacMemoControl.stopReply : .readReply).help)
      .accessibilityIdentifier("mac.detail.play-reply")
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

/// The overflow: the user's own recording, which the speaker must not be mistaken for.
struct MacMoreMenu: View {
  let root: MacCompositionRoot
  let player: MacAudioPlayer
  let memo: Memo

  var body: some View {
    if let request = root.mediaSource.audio(for: memo) {
      let playing = player.isCurrent(memo.id, .recording)
      Menu {
        Button(
          playing
            ? String(localized: "Stop recording", comment: "Detail toolbar: stops the recording")
            : String(localized: "Play recording", comment: "Detail toolbar: plays the recording"),
          systemImage: playing ? "stop.fill" : "play.fill"
        ) { player.toggle(memo.id, .recording, request: request) }
        .help((playing ? MacMemoControl.stopRecording : .playRecording).help)
        .accessibilityIdentifier("mac.detail.play-recording")
      } label: {
        Label(String(localized: "More", comment: "Detail toolbar: overflow menu"), systemImage: "ellipsis.circle")
      }
      .help(MacMemoControl.more.help)
      .accessibilityIdentifier("mac.detail.more")
    }
  }
}
