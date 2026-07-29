import Foundation

/// 磁盘镜像格式。
public enum DiskFormat: String, Sendable, CaseIterable, Codable {
  case raw
  /// 性能更好，但要求宿主机是 macOS 26 (Tahoe) 或更高。
  case asif

  public var displayName: String {
    switch self {
    case .raw: "RAW（通用）"
    case .asif: "ASIF（更快，需 macOS 26+）"
    }
  }
}

/// 新建虚拟机的来源。
public enum VMCreationSource: Sendable, Hashable {
  /// 从 IPSW 安装 macOS。路径可以是本地文件、URL，或字面量 `latest`。
  case macOSFromIPSW(String)
  /// 创建空白的 Linux 虚拟机，随后需要自行挂载安装介质。
  case linux

  /// 取最新支持的 IPSW，由 tart 自动下载。
  public static var latestMacOS: VMCreationSource { .macOSFromIPSW("latest") }
}

/// 显示分辨率的单位提示。
public enum DisplayUnit: String, Sendable, CaseIterable {
  /// 点，macOS 客户机的默认。
  case pt
  /// 像素，Linux 客户机的默认。
  case px
}

extension TartClient {
  // MARK: - 创建

  /// 新建虚拟机。
  ///
  /// 返回流而非直接等待：从 IPSW 安装 macOS 要下载十几 GB 并完成安装，
  /// 耗时可达数十分钟，必须能显示进度。
  public func create(
    name: String,
    source: VMCreationSource,
    diskSizeGB: UInt? = nil,
    diskFormat: DiskFormat? = nil
  ) -> AsyncThrowingStream<CommandEvent, any Error> {
    var arguments = ["create", name]

    switch source {
    case let .macOSFromIPSW(path):
      arguments += ["--from-ipsw", path]
    case .linux:
      arguments.append("--linux")
    }

    if let diskSizeGB {
      arguments += ["--disk-size", String(diskSizeGB)]
    }
    if let diskFormat {
      arguments += ["--disk-format", diskFormat.rawValue]
    }

    return stream(arguments)
  }

  /// 克隆虚拟机。来源可以是本地虚拟机，也可以是 OCI 镜像引用。
  ///
  /// 同样返回流：从远程仓库克隆需要拉取几十 GB。
  public func clone(
    source: String,
    newName: String,
    insecure: Bool = false,
    concurrency: UInt? = nil,
    pruneLimitGB: UInt? = nil
  ) -> AsyncThrowingStream<CommandEvent, any Error> {
    var arguments = ["clone", source, newName]

    if insecure {
      arguments.append("--insecure")
    }
    if let concurrency {
      arguments += ["--concurrency", String(concurrency)]
    }
    if let pruneLimitGB {
      arguments += ["--prune-limit", String(pruneLimitGB)]
    }

    return stream(arguments)
  }

  // MARK: - 配置修改

  /// 修改虚拟机配置。只有显式传入的项会被改动。
  ///
  /// - Important: `diskSizeGB` 只能调大。tart 拒绝缩小磁盘以免丢数据，
  ///   调用方应当在界面上就拦住这种操作，而不是等 tart 报错。
  public func set(
    name: String,
    cpuCount: Int? = nil,
    memoryMB: Int? = nil,
    display: DisplayResolution? = nil,
    displayUnit: DisplayUnit? = nil,
    displayRefit: Bool? = nil,
    randomMAC: Bool = false,
    randomSerial: Bool = false,
    diskSizeGB: Int? = nil
  ) async throws {
    var arguments = ["set", name]

    if let cpuCount {
      arguments += ["--cpu", String(cpuCount)]
    }
    if let memoryMB {
      arguments += ["--memory", String(memoryMB)]
    }
    if let display {
      // 单位是提示性的，不给就由 tart 按客户机类型决定。
      let value = displayUnit.map { "\(display.description)\($0.rawValue)" } ?? display.description
      arguments += ["--display", value]
    }
    if let displayRefit {
      arguments.append(displayRefit ? "--display-refit" : "--no-display-refit")
    }
    if randomMAC {
      arguments.append("--random-mac")
    }
    if randomSerial {
      arguments.append("--random-serial")
    }
    if let diskSizeGB {
      arguments += ["--disk-size", String(diskSizeGB)]
    }

    // 一项都没改就没必要跑一趟。
    guard arguments.count > 2 else { return }

    try await runChecked(arguments)
  }

  /// 重命名虚拟机。
  ///
  /// - Note: 调用方还需要同步搬迁该虚拟机的 Run Profile，
  ///   否则用户配好的启动参数会失联。见 `ProfileCollection.rename`。
  public func rename(name: String, to newName: String) async throws {
    try await runChecked(["rename", name, newName])
  }

  /// 删除虚拟机。不可撤销。
  ///
  /// tart 的 delete 接受多个名字，这里保持一致。
  public func delete(names: [String]) async throws {
    guard !names.isEmpty else { return }
    try await runChecked(["delete"] + names)
  }
}

// MARK: - 磁盘调整校验

public enum DiskResizeValidation {
  /// 检查目标磁盘大小是否可行。
  ///
  /// tart 只允许增大磁盘。与其让用户填完再看报错，不如在界面上直接拦住。
  public static func validate(currentGB: Int, targetGB: Int) -> String? {
    if targetGB < currentGB {
      return "磁盘只能扩大，不能缩小到 \(targetGB) GB（当前 \(currentGB) GB）。缩小会导致数据丢失。"
    }
    if targetGB == currentGB {
      return nil
    }
    return nil
  }

  public static func isValid(currentGB: Int, targetGB: Int) -> Bool {
    targetGB >= currentGB
  }
}
