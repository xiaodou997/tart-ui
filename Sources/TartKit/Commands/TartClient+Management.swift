import Foundation

/// 磁盘镜像格式。
public enum DiskFormat: String, Sendable, CaseIterable, Codable {
  case raw
  /// Apple Silicon + macOS 26 baseline allows TartUI to expose ASIF directly.
  case asif

  public var displayName: String {
    switch self {
    case .raw: "RAW (Universal)"
    case .asif: "ASIF (Faster)"
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
  public func createAction(
    name: String,
    source: VMCreationSource,
    diskSizeGB: UInt? = nil,
    diskFormat: DiskFormat? = nil
  ) -> CommandAction {
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

    return CommandAction(arguments: arguments)
  }

  public func create(
    name: String,
    source: VMCreationSource,
    diskSizeGB: UInt? = nil,
    diskFormat: DiskFormat? = nil
  ) -> AsyncThrowingStream<CommandEvent, any Error> {
    stream(createAction(name: name, source: source, diskSizeGB: diskSizeGB, diskFormat: diskFormat))
  }

  /// 克隆虚拟机。来源可以是本地虚拟机，也可以是 OCI 镜像引用。
  ///
  /// 同样返回流：从远程仓库克隆需要拉取几十 GB。
  public func cloneAction(
    source: String,
    newName: String,
    insecure: Bool = false,
    concurrency: UInt? = nil,
    pruneLimitGB: UInt? = nil
  ) -> CommandAction {
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

    return CommandAction(arguments: arguments)
  }

  public func clone(
    source: String,
    newName: String,
    insecure: Bool = false,
    concurrency: UInt? = nil,
    pruneLimitGB: UInt? = nil
  ) -> AsyncThrowingStream<CommandEvent, any Error> {
    stream(cloneAction(
      source: source,
      newName: newName,
      insecure: insecure,
      concurrency: concurrency,
      pruneLimitGB: pruneLimitGB
    ))
  }

  // MARK: - 配置修改

  /// 修改虚拟机配置。只有显式传入的项会被改动。
  ///
  /// - Important: `diskSizeGB` 只能调大。tart 拒绝缩小磁盘以免丢数据，
  ///   调用方应当在界面上就拦住这种操作，而不是等 tart 报错。
  public func setAction(
    name: String,
    cpuCount: Int? = nil,
    memoryMB: Int? = nil,
    display: DisplayResolution? = nil,
    displayUnit: DisplayUnit? = nil,
    displayRefit: Bool? = nil,
    randomMAC: Bool = false,
    randomSerial: Bool = false,
    diskSizeGB: Int? = nil
  ) -> CommandAction {
    var arguments = ["set", name]

    if let cpuCount {
      arguments += ["--cpu", String(cpuCount)]
    }
    if let memoryMB {
      arguments += ["--memory", String(memoryMB)]
    }
    if let display {
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

    return CommandAction(arguments: arguments)
  }

  @discardableResult
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
  ) async throws -> CommandResult {
    let action = setAction(
      name: name,
      cpuCount: cpuCount,
      memoryMB: memoryMB,
      display: display,
      displayUnit: displayUnit,
      displayRefit: displayRefit,
      randomMAC: randomMAC,
      randomSerial: randomSerial,
      diskSizeGB: diskSizeGB
    )

    guard action.arguments.count > 2 else {
      return CommandResult(arguments: action.arguments, stdout: "", stderr: "", exitCode: 0)
    }

    return try await runChecked(action)
  }

  public func renameAction(name: String, to newName: String) -> CommandAction {
    CommandAction(arguments: ["rename", name, newName])
  }

  @discardableResult
  public func rename(name: String, to newName: String) async throws -> CommandResult {
    try await runChecked(renameAction(name: name, to: newName))
  }

  public func deleteAction(names: [String]) -> CommandAction {
    CommandAction(arguments: ["delete"] + names)
  }

  @discardableResult
  public func delete(names: [String]) async throws -> CommandResult {
    let action = deleteAction(names: names)
    guard !names.isEmpty else {
      return CommandResult(arguments: action.arguments, stdout: "", stderr: "", exitCode: 0)
    }
    return try await runChecked(action)
  }

}

// MARK: - 磁盘调整校验

public enum DiskResizeValidation {
  /// 检查目标磁盘大小是否可行。
  ///
  /// tart 只允许增大磁盘。与其让用户填完再看报错，不如在界面上直接拦住。
  public static func validate(currentGB: Int, targetGB: Int) -> String? {
    if targetGB < currentGB {
      return "The disk can only grow, not shrink to \(targetGB) GB (current size: \(currentGB) GB). Shrinking can cause data loss."
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
