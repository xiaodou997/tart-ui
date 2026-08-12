import Foundation
import TartKit
import TartVMCore

/// 把 TartUI 的启动配置翻译成进程内虚拟机的选项。
///
/// `RunProfile` 的字段是照着 `tart run` 的命令行选项设计的，其中一部分
/// 只对子进程模型有意义。这里明确记录每一项的归属，免得以后有人以为
/// 某个选项「忘了实现」。
extension RunProfile {
  /// 进程内运行时尚未支持的配置项。
  ///
  /// 存在这个类型，是为了让「没实现」变成一次明确的拒绝，而不是悄悄换一个
  /// 行为继续跑。静默降级的代价在这个项目里已经付过：用户选了 Softnet 却
  /// 得到 NAT，界面上看不出任何区别，只有在排查网络问题时才会发现。
  struct UnsupportedOption: Sendable, Hashable, Identifiable {
    public let id = UUID()
    /// 界面上显示的选项名。
    let option: String
    /// 为什么还没支持，以及可以怎么绕开。
    let reason: String
  }

  /// 本次启动中所有无法生效的选项。非空时不应启动虚拟机。
  ///
  /// 说明文案要本地化，所以标注 MainActor——它只在启动前的校验路径上调用。
  @MainActor
  var unsupportedOptions: [UnsupportedOption] {
    var result: [UnsupportedOption] = []

    switch network {
    case .shared, .bridged:
      break
    case .softnet:
      result.append(UnsupportedOption(
        option: "Softnet",
        reason: L10n.text("Softnet runs as a separate helper process that the in-process runtime does not manage yet. Use Shared (NAT) or Bridged instead.")
      ))
    case .hostOnly:
      result.append(UnsupportedOption(
        option: "Host-only",
        reason: L10n.text("Host-only networking is provided by Softnet, which the in-process runtime does not manage yet. Use Shared (NAT) instead.")
      ))
    }

    if vnc || vncExperimental {
      result.append(UnsupportedOption(
        option: "VNC",
        reason: L10n.text("VNC was served by the tart run subprocess. The in-process runtime shows a native window instead; remote access is not implemented yet.")
      ))
    }
    if serial || serialPath != nil {
      result.append(UnsupportedOption(
        option: "Serial port",
        reason: L10n.text("Serial ports require additional device configuration that the in-process runtime does not build yet.")
      ))
    }
    if !disks.isEmpty || rootDiskOptions != nil {
      result.append(UnsupportedOption(
        option: "Additional disks",
        reason: L10n.text("Extra disks and root disk options require additional device configuration that the in-process runtime does not build yet.")
      ))
    }
    if let rosettaTag, !rosettaTag.isEmpty {
      result.append(UnsupportedOption(
        option: "Rosetta",
        reason: L10n.text("Rosetta directory sharing is only meaningful for Linux guests and is not wired up in the in-process runtime yet.")
      ))
    }

    return result
  }

  func tartVMOptions() -> TartVMOptions {
    TartVMOptions(
      network: tartNetworkMode(),
      directoryShares: tartDirectoryShares(),
      suspendable: suspendable,
      nested: nested,
      audio: !noAudio,
      clipboard: !noClipboard,
      noTrackpad: noTrackpad,
      noPointer: noPointer,
      noKeyboard: noKeyboard
    )
    // 有意不映射的字段（它们不是缺口）：
    //
    // recovery          —— 不属于机器配置，作为参数传给 start(recovery:)。
    // noGraphics        —— 等于「不开窗口」，由协调器决定，不影响虚拟机配置。
    // captureSystemKeys —— 属于窗口行为，交给 VZVirtualMachineView。
    //
    // 其余尚未支持的字段由 unsupportedOptions 负责拦截，不在这里静默忽略。
  }

  private func tartNetworkMode() -> TartNetworkMode {
    switch network {
    case .shared:
      return .shared
    case let .bridged(interface):
      return interface.isEmpty ? .shared : .bridged(interfaceName: interface)
    case .hostOnly, .softnet:
      // 走到这里说明调用方没有先检查 unsupportedOptions。返回 NAT 只是为了
      // 让类型完整，启动路径上不应该出现这种情况。
      return .shared
    }
  }

  private func tartDirectoryShares() -> [TartDirectoryShare] {
    directoryShares.compactMap(Self.parseDirectoryShare)
  }

  /// 解析 `tart run --dir` 的 `[name:]path[:options]` 格式。
  ///
  /// 这个格式是命令行的产物。界面上应该逐步换成结构化输入，但存量 profile
  /// 里存的是字符串，这里先保证它们仍然可用。
  static func parseDirectoryShare(_ raw: String) -> TartDirectoryShare? {
    var remainder = raw
    var readOnly = false

    // 结尾的 :ro / :rw 是选项，不是路径的一部分。
    for suffix in [":ro", ":rw"] where remainder.hasSuffix(suffix) {
      readOnly = suffix == ":ro"
      remainder = String(remainder.dropLast(suffix.count))
    }

    guard !remainder.isEmpty else { return nil }

    // `name:path` 里的冒号只在第一段之后才是分隔符；绝对路径本身不含冒号，
    // 所以以 / 或 ~ 开头就说明没有名字部分。
    //
    // 未命名时 name 必须保持 nil，不能拿路径末段顶上：单个未命名共享在
    // 客户机里挂载的位置和命名共享不一样，自动补名字会改变客户机看到的
    // 目录结构。
    let name: String?
    let path: String
    if remainder.hasPrefix("/") || remainder.hasPrefix("~") {
      path = remainder
      name = nil
    } else if let separator = remainder.firstIndex(of: ":") {
      let parsed = String(remainder[remainder.startIndex..<separator])
      name = parsed.isEmpty ? nil : parsed
      path = String(remainder[remainder.index(after: separator)...])
    } else {
      path = remainder
      name = nil
    }

    guard !path.isEmpty else { return nil }
    return TartDirectoryShare(
      name: name,
      url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true),
      readOnly: readOnly
    )
  }
}
