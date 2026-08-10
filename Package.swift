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
    // CLI 封装层：不依赖任何 UI 代码，可脱离界面单独测试。
    .target(name: "TartKit"),

    .executableTarget(
      name: "TartUI",
      dependencies: ["TartKit"],
      resources: [.process("Resources")]
    ),

    .testTarget(name: "TartKitTests", dependencies: ["TartKit"]),
  ]
)
