import SwiftUI

/// Which spoken form of the reply to play: the short summary or the whole reply.
public enum ReplyPlayChoice: Hashable, Sendable {
  case summary
  case full
}

/// The "Play reply" control in the footer of Iris's bubble: a speaker with its label that opens a menu of the two spoken forms
/// (the summary first, then the full reply), and a stop square with "Stop reply" while the reply speaks. The playback lives with
/// the caller.
public struct ReplyPlayButton: View {
  private let isPlaying: Bool
  private let onPlay: (ReplyPlayChoice) -> Void
  private let onStop: () -> Void

  public init(isPlaying: Bool, onPlay: @escaping (ReplyPlayChoice) -> Void, onStop: @escaping () -> Void) {
    self.isPlaying = isPlaying
    self.onPlay = onPlay
    self.onStop = onStop
  }

  public var body: some View {
    if isPlaying {
      Button(action: onStop) {
        label {
          Text("Stop reply", bundle: #bundle, comment: "Label of the stop button while the reply plays")
        } icon: {
          Image(systemName: "stop.fill")
        }
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("detail.action.play")
    } else {
      Menu {
        Button {
          onPlay(.summary)
        } label: {
          Label {
            Text("Read the summary", bundle: #bundle, comment: "Menu item: speaks the short summary of the reply")
          } icon: {
            Image(systemName: "text.quote")
          }
        }
        .accessibilityIdentifier("detail.action.play.summary")
        Button {
          onPlay(.full)
        } label: {
          Label {
            Text("Read the full reply", bundle: #bundle, comment: "Menu item: speaks the whole reply")
          } icon: {
            Image(systemName: "text.alignleft")
          }
        }
        .accessibilityIdentifier("detail.action.play.full")
      } label: {
        label {
          Text("Play reply", bundle: #bundle, comment: "Label of the button that speaks the reply")
        } icon: {
          Image(systemName: "speaker.wave.2")
        }
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .accessibilityIdentifier("detail.action.play")
    }
  }

  private func label<Title: View, Icon: View>(
    @ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon
  ) -> some View {
    Label {
      title()
    } icon: {
      icon()
    }
    .themeFont(.footnote, weight: .semibold)
    .foregroundStyle(Theme.Accent.tint)
    .frame(minHeight: Theme.Spacing.tapTarget, alignment: .leading)
    .contentShape(.rect)
  }
}
