import AppKit

/// 处理应用退出时对运行中虚拟机的确认。
///
/// 实测确认：`tart run` 是 TartPro 的子进程，但 TartPro 退出后它会被移交给
/// launchd 并继续运行，虚拟机不会被连带关闭。所以这里默认不杀——
/// 虚拟机是重资产，误杀等同于拔电源，有丢数据的风险。
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// 由 App 在启动时注入，返回当前由 TartPro 管理的运行中虚拟机名称。
  ///
  /// AppDelegate 拿不到 SwiftUI 的 @State，只能用这种方式取数据。
  @MainActor static var runningVMNamesProvider: (() -> [String])?

  @MainActor
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let running = Self.runningVMNamesProvider?() ?? []
    guard !running.isEmpty else { return .terminateNow }

    let alert = NSAlert()
    alert.messageText = "还有 \(running.count) 台虚拟机在运行"
    alert.informativeText = """
      \(running.joined(separator: "、"))

      退出 TartPro 不会关闭这些虚拟机，它们会继续在后台运行。
      要关闭它们，请先在界面上执行关机，或稍后用 `tart stop` 命令。
      """
    alert.alertStyle = .warning
    alert.addButton(withTitle: "仍然退出")
    alert.addButton(withTitle: "取消")

    return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
