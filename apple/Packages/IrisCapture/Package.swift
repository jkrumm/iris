// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "IrisCapture",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "IrisCapture", targets: ["IrisCapture"])
  ],
  targets: [
    // Turns the Objective-C exceptions AVAudioEngine raises (a tap format that disagrees with the hardware) into errors.
    .target(name: "IrisObjCGuard"),
    .target(name: "IrisCapture", dependencies: ["IrisObjCGuard"]),
    .testTarget(name: "IrisCaptureTests", dependencies: ["IrisCapture", "IrisObjCGuard"]),
  ],
  swiftLanguageModes: [.v6]
)
