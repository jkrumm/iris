// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "IrisUI",
  defaultLocalization: "en",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "IrisUI", targets: ["IrisUI"])
  ],
  dependencies: [
    .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.7")
  ],
  targets: [
    .target(
      name: "IrisUI",
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "IrisUITests",
      dependencies: [
        "IrisUI",
        .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
      ],
      exclude: ["__Snapshots__"]
    ),
  ],
  swiftLanguageModes: [.v6]
)
