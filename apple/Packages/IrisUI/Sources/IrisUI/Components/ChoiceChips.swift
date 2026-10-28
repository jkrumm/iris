import SwiftUI

/// One choice of a ``ChoiceChips`` row.
public struct ChipChoice<ID: Hashable & Sendable>: Identifiable, Sendable {
  public var id: ID
  public var title: String
  public var systemImage: String?

  public init(id: ID, title: String, systemImage: String? = nil) {
    self.id = id
    self.title = title
    self.systemImage = systemImage
  }
}

/// A single-choice row of chips (the composer's mode picker); it wraps when the row is full.
public struct ChoiceChips<ID: Hashable & Sendable>: View {
  private let choices: [ChipChoice<ID>]
  @Binding private var selection: ID

  public init(choices: [ChipChoice<ID>], selection: Binding<ID>) {
    self.choices = choices
    _selection = selection
  }

  public var body: some View {
    ChipFlowLayout {
      ForEach(choices) { choice in
        FilterChip(title: choice.title, systemImage: choice.systemImage, isOn: choice.id == selection) {
          selection = choice.id
        }
      }
    }
  }
}
