// swift-tools-version:6.0

import PackageDescription

let package = Package(
  name: "TartPro",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "TartKit", targets: ["TartKit"]),
    .executable(name: "TartPro", targets: ["TartPro"]),
  ],
  targets: [
    // CLI 封装层：不依赖任何 UI 代码，可脱离界面单独测试。
    .target(name: "TartKit"),

    .executableTarget(name: "TartPro", dependencies: ["TartKit"]),

    .testTarget(name: "TartKitTests", dependencies: ["TartKit"]),
  ]
)
