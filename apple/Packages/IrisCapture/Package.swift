// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "IrisCapture",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "IrisCapture", targets: ["IrisCapture"])
  ],
  targets: [
    .target(name: "IrisCapture"),
    .testTarget(name: "IrisCaptureTests", dependencies: ["IrisCapture"]),
  ],
  swiftLanguageModes: [.v6]
)
