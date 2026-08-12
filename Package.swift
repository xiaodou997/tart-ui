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
    .library(name: "TartVMCore", targets: ["TartVMCore"]),
    .executable(name: "TartUI", targets: ["TartUI"]),
  ],
  dependencies: [
    // 版本与 Vendor/tart/Package.swift 保持一致，避免同一份源码在两处被
    // 不同版本的依赖编译。
    .package(url: "https://github.com/groue/Semaphore", from: "0.0.8"),
    .package(url: "https://github.com/apple/swift-atomics.git", .upToNextMajor(from: "1.2.0")),
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.6.1"),
    .package(url: "https://github.com/jozefizso/swift-xattr", from: "3.0.0"),
    // ControlSocket 用 NIO 实现。它不是可选组件：客户机里的 guest agent
    // 依赖这条通道，宿主不监听时客户机会反复重启。
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
  ],
  targets: [
    // CLI 封装层：不依赖任何 UI 代码，可脱离界面单独测试。
    .target(name: "TartKit"),

    // Tart 的虚拟机核心，直接编译 Vendor/tart 的源码子集。
    //
    // 这里刻意不修改 Vendor/tart/Package.swift：那样会让同一目录被两个
    // target 共享，SPM 不允许，且必须把文件物理搬走、大范围加 public，
    // 每次上游更新都要处理冲突。改成由 TartUI 自己挑选源码文件，
    // Vendor/tart 就能保持逐字节等于上游。
    //
    // 白名单只包含跑起 VZVirtualMachine 所需的最小闭包；OCI / Registry /
    // CLI 子命令不在其中，那些能力仍然通过 tart 命令行子进程使用。
    .target(
      name: "TartVMCore",
      dependencies: [
        .product(name: "Semaphore", package: "Semaphore"),
        .product(name: "Atomics", package: "swift-atomics"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "XAttr", package: "swift-xattr"),
        .product(name: "NIO", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ],
      // target 的根设在仓库根，这样门面文件能和 Vendor/tart 的源码编进同一个
      // target：门面因此可以访问 Tart 的 internal 类型，而不必给上游批量加
      // public，同时它自己留在 TartUI 仓库里，不污染 fork。
      path: ".",
      sources: [
        // TartUI 自己的门面，定义 TartUI 需要的最小接口。
        "Sources/TartVMCore",

        // 以下全部来自 Vendor/tart，逐字节等于上游（除两个纯移动 commit）。
        "Vendor/tart/Sources/tart/VM.swift",
        "Vendor/tart/Sources/tart/VMConfig.swift",
        "Vendor/tart/Sources/tart/VMDirectory.swift",
        "Vendor/tart/Sources/tart/DiskImageFormat.swift",
        "Vendor/tart/Sources/tart/RuntimeError.swift",
        "Vendor/tart/Sources/tart/GuestProvisioningOptions.swift",
        "Vendor/tart/Sources/tart/Config.swift",
        "Vendor/tart/Sources/tart/Utils.swift",
        "Vendor/tart/Sources/tart/Fetcher.swift",
        "Vendor/tart/Sources/tart/FileLock.swift",
        "Vendor/tart/Sources/tart/PIDLock.swift",
        "Vendor/tart/Sources/tart/IPSWCache.swift",
        "Vendor/tart/Sources/tart/Diskutil.swift",
        "Vendor/tart/Sources/tart/Prunable.swift",
        "Vendor/tart/Sources/tart/URL+AccessDate.swift",
        "Vendor/tart/Sources/tart/URL+Prunable.swift",
        "Vendor/tart/Sources/tart/Network/Network.swift",
        "Vendor/tart/Sources/tart/Network/NetworkShared.swift",
        "Vendor/tart/Sources/tart/Network/NetworkBridged.swift",
        "Vendor/tart/Sources/tart/Network/Softnet.swift",
        "Vendor/tart/Sources/tart/Platform/Platform.swift",
        "Vendor/tart/Sources/tart/Platform/OS.swift",
        "Vendor/tart/Sources/tart/Platform/Darwin.swift",
        "Vendor/tart/Sources/tart/Platform/Linux.swift",
        "Vendor/tart/Sources/tart/Platform/Architecture.swift",
        "Vendor/tart/Sources/tart/OCI/Digest.swift",
        "Vendor/tart/Sources/tart/Logging/Logger.swift",
        "Vendor/tart/Sources/tart/Logging/ProgressObserver.swift",
      ],
      swiftSettings: [
        // 上游 Vendor/tart 是 swift-tools-version 5.10，按 Swift 5 语言模式
        // 编写；TartUI 自己用 6.0。同一份源码在 Swift 6 严格并发下会报出
        // 大量 Sendable / 全局可变状态错误。锁定这个 target 用 Swift 5 模式，
        // 就不必为了迁就 TartUI 去改上游代码。
        .swiftLanguageMode(.v5),
      ]
    ),

    .executableTarget(
      name: "TartUI",
      dependencies: ["TartKit", "TartVMCore"],
      resources: [.process("Resources")]
    ),

    // 诊断工具：用与 TartUI 相同的 TartVMCore 路径启动虚拟机，用来区分
    // 问题出在配置层还是界面层。
    .executableTarget(name: "TartVMProbe", dependencies: ["TartVMCore"]),

    .testTarget(name: "TartKitTests", dependencies: ["TartKit"]),
    .testTarget(name: "TartUITests", dependencies: ["TartUI", "TartKit"]),
  ]
)
