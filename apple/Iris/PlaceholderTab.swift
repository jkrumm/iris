import IrisUI
import SwiftUI

/// A tab that exists so the shell is complete; Wave 14 fills Stats and Settings.
struct PlaceholderTab: View {
  let title: String

  var body: some View {
    NavigationStack {
      ContentUnavailableView(
        title, systemImage: "hammer",
        description: Text("Coming soon.", comment: "Placeholder tab body")
      )
      .background(Theme.Surface.background)
      .navigationTitle(title)
    }
  }
}
