import Foundation

/// 一份具名的启动配置。
///
/// 这是 TartUI 相对命令行的主要增值点：`tart run` 有二十多个选项，
/// 但 tart 的 `config.json` 只持久化 CPU、内存、显示等六个字段。
/// 命令行用户每次启动都得重敲一长串参数，TartUI 把它们存下来复用。
///
/// 一台虚拟机可以有多份 profile（如「日常开发」「无图形跑测试」）。
public struct RunProfile: Codable, Sendable, Hashable, Identifiable {
  public var id: UUID
  /// profile 的显示名，不是虚拟机名。
  public var name: String

  // MARK: 显示与输入

  /// 不打开 UI 窗口。适合只用 SSH / VNC 访问的场景。
  public var noGraphics: Bool
  /// 用「屏幕共享」代替内置窗口。需要虚拟机内开启远程登录。
  public var vnc: Bool
  /// 用 Virtualization.Framework 的 VNC 服务。恢复模式和安装过程中也可用，但官方标注为实验性。
  public var vncExperimental: Bool
  /// 把 Cmd+Tab 这类系统快捷键送给虚拟机而不是宿主机。
  public var captureSystemKeys: Bool
  public var noTrackpad: Bool
  public var noPointer: Bool
  public var noKeyboard: Bool

  // MARK: 设备

  public var noAudio: Bool
  public var noClipboard: Bool
  /// 关闭音频和熵设备，换成 Mac 专用输入设备，这样才能被 `tart suspend` 挂起。
  public var suspendable: Bool
  public var nested: Bool
  public var recovery: Bool

  // MARK: 串口

  public var serial: Bool
  public var serialPath: String?

  // MARK: 存储与共享

  /// 附加磁盘，格式为 `path[:options]`。
  public var disks: [String]
  /// 根磁盘选项，如 `ro` 或 `caching=cached,sync=none`。
  public var rootDiskOptions: String?
  /// 目录共享，格式为 `[name:]path[:options]`。
  public var directoryShares: [String]
  /// Rosetta 共享的挂载标签，仅对 Linux 客户机有意义。
  public var rosettaTag: String?

  // MARK: 网络

  public var network: NetworkMode

  public init(
    id: UUID = UUID(),
    name: String = "Default",
    noGraphics: Bool = false,
    vnc: Bool = false,
    vncExperimental: Bool = false,
    captureSystemKeys: Bool = false,
    noTrackpad: Bool = false,
    noPointer: Bool = false,
    noKeyboard: Bool = false,
    noAudio: Bool = false,
    noClipboard: Bool = false,
    suspendable: Bool = false,
    nested: Bool = false,
    recovery: Bool = false,
    serial: Bool = false,
    serialPath: String? = nil,
    disks: [String] = [],
    rootDiskOptions: String? = nil,
    directoryShares: [String] = [],
    rosettaTag: String? = nil,
    network: NetworkMode = .shared
  ) {
    self.id = id
    self.name = name
    self.noGraphics = noGraphics
    self.vnc = vnc
    self.vncExperimental = vncExperimental
    self.captureSystemKeys = captureSystemKeys
    self.noTrackpad = noTrackpad
    self.noPointer = noPointer
    self.noKeyboard = noKeyboard
    self.noAudio = noAudio
    self.noClipboard = noClipboard
    self.suspendable = suspendable
    self.nested = nested
    self.recovery = recovery
    self.serial = serial
    self.serialPath = serialPath
    self.disks = disks
    self.rootDiskOptions = rootDiskOptions
    self.directoryShares = directoryShares
    self.rosettaTag = rosettaTag
    self.network = network
  }
}

// MARK: - 参数生成

extension RunProfile {
  /// 生成 `tart run` 的完整参数列表。
  ///
  /// 只有偏离默认值的选项才会出现在结果里——生成一串全是默认值的参数
  /// 既没必要，也让用户在日志里看不清自己到底改了什么。
  public func arguments(vmName: String) -> [String] {
    var arguments = ["run", vmName]

    // 显示与输入
    if noGraphics { arguments.append("--no-graphics") }
    if vnc { arguments.append("--vnc") }
    if vncExperimental { arguments.append("--vnc-experimental") }
    if captureSystemKeys { arguments.append("--capture-system-keys") }
    if noTrackpad { arguments.append("--no-trackpad") }
    if noPointer { arguments.append("--no-pointer") }
    if noKeyboard { arguments.append("--no-keyboard") }

    // 设备
    if noAudio { arguments.append("--no-audio") }
    if noClipboard { arguments.append("--no-clipboard") }
    if suspendable { arguments.append("--suspendable") }
    if nested { arguments.append("--nested") }
    if recovery { arguments.append("--recovery") }

    // 串口
    if serial { arguments.append("--serial") }
    if let serialPath, !serialPath.isEmpty {
      arguments += ["--serial-path", serialPath]
    }

    // 存储与共享
    for disk in disks where !disk.isEmpty {
      arguments.append("--disk=\(disk)")
    }
    if let rootDiskOptions, !rootDiskOptions.isEmpty {
      arguments.append("--root-disk-opts=\(rootDiskOptions)")
    }
    for share in directoryShares where !share.isEmpty {
      arguments.append("--dir=\(share)")
    }
    if let rosettaTag, !rosettaTag.isEmpty {
      arguments.append("--rosetta=\(rosettaTag)")
    }

    arguments += networkArguments()

    return arguments
  }

  private func networkArguments() -> [String] {
    switch network {
    case .shared:
      // 默认的 NAT 网络，不需要任何参数。
      return []

    case let .bridged(interface):
      guard !interface.isEmpty else { return [] }
      return ["--net-bridged=\(interface)"]

    case .hostOnly:
      return ["--net-host"]

    case let .softnet(options):
      var arguments = ["--net-softnet"]
      if !options.allowedCIDRs.isEmpty {
        arguments.append("--net-softnet-allow=\(options.allowedCIDRs.joined(separator: ","))")
      }
      if !options.blockedCIDRs.isEmpty {
        arguments.append("--net-softnet-block=\(options.blockedCIDRs.joined(separator: ","))")
      }
      if !options.exposedPorts.isEmpty {
        let spec = options.exposedPorts.map(\.argumentValue).joined(separator: ",")
        arguments.append("--net-softnet-expose=\(spec)")
      }
      return arguments
    }
  }
}

// MARK: - 校验

extension RunProfile {
  /// 配置中自相矛盾或不合理之处。
  ///
  /// tart 自己也会拒绝一部分组合，但等到启动失败才报错，用户已经白等了一轮；
  /// 在界面上提前提示体验更好。
  public struct Warning: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public let message: String
    /// 为 true 表示 tart 会直接拒绝启动；为 false 表示只是可能不符合预期。
    public let isBlocking: Bool
  }

  public func validate() -> [Warning] {
    var warnings: [Warning] = []

    if vnc && vncExperimental {
      warnings.append(Warning(
        message: "Screen Sharing and Experimental VNC cannot be enabled together. Choose one.",
        isBlocking: true
      ))
    }

    if noGraphics && !vnc && !vncExperimental {
      warnings.append(Warning(
        message: "The graphics window is disabled and no VNC mode is enabled; the VM will only be accessible through SSH.",
        isBlocking: false
      ))
    }

    if suspendable && noAudio {
      warnings.append(Warning(
        message: "Suspendable already disables audio; disabling audio separately is unnecessary.",
        isBlocking: false
      ))
    }

    if recovery && suspendable {
      warnings.append(Warning(
        message: "The VM cannot be suspended in recovery mode.",
        isBlocking: false
      ))
    }

    if case let .softnet(options) = network {
      for port in options.exposedPorts {
        if !(1...65535).contains(port.hostPort) || !(1...65535).contains(port.guestPort) {
          warnings.append(Warning(
            message: "Port \(port.argumentValue) is outside the valid range 1–65535.",
            isBlocking: true
          ))
        }
      }
      // 端口转发要能从外部访问，通常还需要放行对应网段，否则 Softnet 的默认策略会拦掉。
      if !options.exposedPorts.isEmpty && options.allowedCIDRs.isEmpty {
        warnings.append(Warning(
          message: "Port forwarding is configured without allowed networks; Softnet's default restrictions may block external connections.",
          isBlocking: false
        ))
      }
    }

    if serial && serialPath != nil {
      warnings.append(Warning(
        message: "Open Serial Console and External Serial Path are alternative modes; enabling both may not work as expected.",
        isBlocking: false
      ))
    }

    return warnings
  }

  /// 是否存在会导致启动失败的问题。
  public var hasBlockingIssues: Bool {
    validate().contains { $0.isBlocking }
  }
}
