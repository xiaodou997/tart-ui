import Foundation
import TartKit
import TartVMCore

/// 把 TartUI 的启动配置翻译成进程内虚拟机的选项。
///
/// `RunProfile` 的字段是照着 `tart run` 的命令行选项设计的，其中一部分
/// 只对子进程模型有意义。这里明确记录每一项的归属，免得以后有人以为
/// 某个选项「忘了实现」。
extension RunProfile {
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
    // 未映射的字段，各有原因：
    //
    // recovery         —— 不属于机器配置，作为参数传给 start(recovery:)。
    // noGraphics       —— 现在等于「不开窗口」，由协调器决定，不影响虚拟机配置。
    // captureSystemKeys—— 属于窗口/视图行为，交给 VZVirtualMachineView。
    // vnc / vncExperimental
    //                  —— 上游由 `tart run` 自己起 VNC 服务。进程内模式下窗口
    //                     就是原生的，VNC 只在远程访问时才有意义；这部分留到
    //                     后面单独做，届时直接用 Virtualization 的接口，而不是
    //                     再去起一个 tart 子进程。
    // serial / serialPath / disks / rootDiskOptions / rosettaTag
    //                  —— 需要构造额外的 VZ 设备配置，门面暂未暴露对应参数。
    //                     这些字段目前在进程内模式下不生效，属于已知缺口。
  }

  private func tartNetworkMode() -> TartNetworkMode {
    switch network {
    case .shared:
      return .shared
    case let .bridged(interface):
      return interface.isEmpty ? .shared : .bridged(interfaceName: interface)
    case .hostOnly, .softnet:
      // Softnet 是一个独立的辅助进程，上游通过 `tart run --net-softnet` 拉起。
      // 进程内模式要复用它需要额外接管其生命周期，暂时回退到 NAT，
      // 而不是假装配置成功。
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
