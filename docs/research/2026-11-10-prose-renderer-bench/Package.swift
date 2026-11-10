// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ProseRendererBench",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/microsoft/SwiftStreamingMarkdown", revision: "5f7c04e0558df6146f90d482edb62cb456986bda"), // tag 0.7.0, pinned by revision: a version requirement cannot resolve (README)
        .package(url: "https://github.com/Lakr233/MarkdownView", exact: "4.8.5"),
    ],
    targets: [
        .target(name: "BenchCore"),
        .executableTarget(
            name: "BenchSSM",
            dependencies: [
                "BenchCore",
                .product(name: "SwiftStreamingMarkdown", package: "SwiftStreamingMarkdown"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "BenchMV",
            dependencies: [
                "BenchCore",
                .product(name: "MarkdownView", package: "MarkdownView"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
