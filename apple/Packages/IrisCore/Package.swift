// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "IrisCore",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "IrisCore", targets: ["IrisCore"])
  ],
  targets: [
    .target(name: "IrisCore"),
    .testTarget(name: "IrisCoreTests", dependencies: ["IrisCore"]),
  ],
  swiftLanguageModes: [.v6]
)
