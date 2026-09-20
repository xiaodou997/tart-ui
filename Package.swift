// swift-tools-version:6.0

import PackageDescription

let package = Package(
  name: "TartUI",
  defaultLocalization: "en",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "TartKit", targets: ["TartKit"]),
    .executable(name: "TartUI", targets: ["TartUI"]),
  ],
  targets: [
    // Thin wrapper around the official tart CLI. No virtualization implementation
    // lives in TartUI.
    .target(name: "TartKit"),

    .executableTarget(
      name: "TartUI",
      dependencies: ["TartKit"],
      resources: [.process("Resources")]
    ),

    .testTarget(name: "TartKitTests", dependencies: ["TartKit"]),
    .testTarget(name: "TartUITests", dependencies: ["TartUI", "TartKit"]),
  ]
)
