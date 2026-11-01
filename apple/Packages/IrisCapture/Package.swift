// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "IrisCapture",
  defaultLocalization: "en",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "IrisCapture", targets: ["IrisCapture"])
  ],
  targets: [
    // Turns the Objective-C exceptions AVAudioEngine raises (a tap format that disagrees with the hardware) into errors.
    .target(name: "IrisObjCGuard"),
    .target(name: "IrisCapture", dependencies: ["IrisObjCGuard"], resources: [.process("Resources")]),
    .testTarget(name: "IrisCaptureTests", dependencies: ["IrisCapture", "IrisObjCGuard"]),
  ],
  swiftLanguageModes: [.v6]
)
