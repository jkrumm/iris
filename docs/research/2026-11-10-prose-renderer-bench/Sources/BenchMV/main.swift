import AppKit
import BenchCore
import MarkdownView

// Lakr233/MarkdownView: every snapshot is parsed (sync, cmark-gfm), pre-rendered into a
// MarkdownContent, pushed with setContentImmediately (unthrottled) into a MarkdownTextView and
// measured with boundingSize(for: 390), which runs the Litext/CoreText layout.
// Timed per update: parse + MarkdownContent (attributed strings, math, highlight) + set + layout.

let width: CGFloat = 390
let body: CGFloat = 16

@MainActor
func makeTheme() -> MarkdownTheme {
    var theme = MarkdownTheme()
    theme.fonts.body = NSFont.systemFont(ofSize: body)
    theme.fonts.bold = NSFont.systemFont(ofSize: body, weight: .semibold)
    theme.fonts.italic = NSFont(
        descriptor: NSFont.systemFont(ofSize: body).fontDescriptor.withSymbolicTraits(.italic), size: body)
        ?? NSFont.systemFont(ofSize: body)
    theme.fonts.codeInline = NSFont.monospacedSystemFont(ofSize: body, weight: .regular)
    theme.fonts.code = NSFont.monospacedSystemFont(ofSize: ceil(body * 0.85), weight: .regular)
    theme.fonts.title = NSFont.systemFont(ofSize: body, weight: .bold)
    theme.fonts.largeTitle = NSFont.systemFont(ofSize: body, weight: .bold)
    return theme
}

func descendants(of view: NSView) -> Int {
    view.subviews.reduce(view.subviews.count) { $0 + descendants(of: $1) }
}

@main
struct BenchMV {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let snapshots = ProseFixture.snapshots()
        let theme = makeTheme()
        let clock = ContinuousClock()
        var passes: [[Double]] = []
        var lastSize = CGSize.zero
        var lastViews = 0

        for pass in 1 ... 3 {
            let view = MarkdownTextView()
            view.theme = theme
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            var samples: [Double] = []
            for snapshot in snapshots {
                let start = clock.now
                let content = MarkdownContent(markdown: snapshot, theme: theme)
                view.setContentImmediately(content)
                let size = view.boundingSize(for: width)
                view.setFrameSize(NSSize(width: width, height: size.height))
                view.layoutSubtreeIfNeeded()
                samples.append(milliseconds(clock.now - start))
                lastSize = size
            }
            lastViews = descendants(of: view)
            FileHandle.standardError.write(Data("pass \(pass) done\n".utf8))
            passes.append(samples)
            window.contentView = nil
        }
        print("MarkdownView 4.8.5: \(snapshots.count) snapshots, final size \(Int(lastSize.width))x\(Int(lastSize.height)) pt, \(lastViews) NSViews")
        report(name: "MarkdownView", passes: passes)
    }
}
