import AppKit
import Testing

@testable import IrisMac

@MainActor
@Suite("Mac text selection")
struct MacTextSelectionTests {
  @Test("a click takes the first responder away from selectable text, not from a list or an editable field")
  func whoResigns() {
    let selectable = NSTextView()
    selectable.isEditable = false
    selectable.isSelectable = true
    let field = NSTextView()
    field.isEditable = true
    #expect(MacTextSelection.shouldResign(selectable), "selected text is cleared by a click elsewhere")
    #expect(MacTextSelection.shouldResign(NSView()), "any other view that holds focus gives it up")
    #expect(!MacTextSelection.shouldResign(field), "the composer keeps its caret")
    #expect(!MacTextSelection.shouldResign(NSTableView()), "the list keeps arrow keys and the Delete key")
    #expect(!MacTextSelection.shouldResign(NSOutlineView()))
    #expect(!MacTextSelection.shouldResign(nil))
    #expect(!MacTextSelection.shouldResign(NSWindow()), "nothing holds focus, nothing to clear")
  }
}
