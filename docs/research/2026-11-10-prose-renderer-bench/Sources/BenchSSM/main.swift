import AppKit
import BenchCore
import SwiftStreamingMarkdown
import SwiftUI

// microsoft/SwiftStreamingMarkdown: every snapshot is parsed (async, swift-markdown) into a
// RenderableDocument, handed to DocumentView inside an NSHostingView at 390 pt, and laid out.
// Timed per update: parse + rootView swap + layoutSubtreeIfNeeded + fittingSize + one runloop turn.

let width: CGFloat = 390
let body: CGFloat = 16

func fonts(_ size: CGFloat) -> TextFonts {
    let normal = NSFont.systemFont(ofSize: size)
    let bold = NSFont.systemFont(ofSize: size, weight: .semibold)
    func italic(_ f: NSFont) -> NSFont {
        NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? f
    }
    return TextFonts(
        normal: normal, italic: italic(normal), bold: bold, boldItalic: italic(bold),
        preferredLetterSpacing: nil, preferredLineHeight: nil)
}

let base = MarkdownRenderConfig.default
let config = base
    .withShouldAnimateText(value: false)
    .withParagraphStyle(value: .init(textFonts: fonts(body), textColor: base.paragraphStyle.textColor))
    .withOrderedListStyle(value: .init(textFonts: fonts(body), textColor: base.orderedListStyle.textColor))
    .withBlockQuoteStyle(value: .init(textFonts: fonts(body), textColor: base.blockQuoteStyle.textColor))

struct Root: View {
    let document: RenderableDocument
    var body: some View {
        DocumentView(renderableDocument: document, config: config)
            .frame(width: width)
    }
}

func descendants(of view: NSView) -> Int {
    view.subviews.reduce(view.subviews.count) { $0 + descendants(of: $1) }
}

@main
struct BenchSSM {
    @MainActor
    static func main() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        let snapshots = ProseFixture.snapshots()
        let parser = MarkdownParserImpl()
        let clock = ContinuousClock()
        var passes: [[Double]] = []
        var lastHeight: CGFloat = 0
        var lastViews = 0

        for pass in 1 ... 3 {
            let host = NSHostingView(rootView: Root(document: .empty))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            var samples: [Double] = []
            for snapshot in snapshots {
                let start = clock.now
                let document = await parser.parse(text: snapshot, config: config)
                host.rootView = Root(document: document)
                host.layoutSubtreeIfNeeded()
                let size = host.fittingSize
                host.setFrameSize(NSSize(width: width, height: size.height))
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(mode: .default, before: .now)
                samples.append(milliseconds(clock.now - start))
                lastHeight = size.height
            }
            lastViews = descendants(of: host)
            FileHandle.standardError.write(Data("pass \(pass) done\n".utf8))
            passes.append(samples)
            window.contentView = nil
        }
        print("SwiftStreamingMarkdown 0.7.0: \(snapshots.count) snapshots, final height \(Int(lastHeight)) pt, \(lastViews) NSViews")
        report(name: "SwiftStreamingMarkdown", passes: passes)
    }
}
