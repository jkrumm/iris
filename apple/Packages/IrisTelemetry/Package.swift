// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "IrisTelemetry",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "IrisTelemetry", targets: ["IrisTelemetry"])
  ],
  targets: [
    .target(name: "IrisTelemetry"),
    .testTarget(name: "IrisTelemetryTests", dependencies: ["IrisTelemetry"]),
  ],
  swiftLanguageModes: [.v6]
)
