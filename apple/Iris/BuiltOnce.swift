import SwiftUI

/// A destination that builds its model once, when it first renders, and keeps it. A navigation destination or sheet closure
/// runs on every evaluation of the screen that owns it; building the model there made one (and a Keychain read) per
/// evaluation that the destination's own `@State` then threw away. The factory is called by the first `body` only.
///
/// Key it with `.id(...)` of what the model is for (the memo, the route, the composer request): a different one is a different
/// destination and builds its own model.
struct BuiltOnce<Model, Content: View>: View {
  @State private var box = BuiltModel<Model>()
  let make: () -> Model
  @ViewBuilder let content: (Model) -> Content

  var body: some View {
    content(box.resolve(make))
  }
}

/// What ``BuiltOnce`` keeps in its `@State`: the model, built by the first `resolve`.
private final class BuiltModel<Model> {
  private var model: Model?

  func resolve(_ make: () -> Model) -> Model {
    if let model { return model }
    let built = make()
    model = built
    return built
  }
}
