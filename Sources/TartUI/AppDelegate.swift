import AppKit

/// 处理应用退出时对运行中虚拟机的确认。
///
/// `tart run` 是 TartUI 的 runtime helper 子进程，但 TartUI 退出后它会被移交给
/// launchd 并继续运行，虚拟机不会被连带关闭。所以这里默认不杀——
/// 虚拟机是重资产，误杀等同于拔电源，有丢数据的风险。
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// 由 App 在启动时注入，返回当前由 TartUI 管理的运行中虚拟机名称。
  ///
  /// AppDelegate 拿不到 SwiftUI 的 @State，只能用这种方式取数据。
  @MainActor static var runningVMNamesProvider: (() -> [String])?

  @MainActor
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let running = Self.runningVMNamesProvider?() ?? []
    guard !running.isEmpty else { return .terminateNow }

    let alert = NSAlert()
    alert.messageText = L10n.format("%@ VM(s) are still running", String(running.count))
    alert.informativeText = L10n.format(
      "%@\n\nQuitting TartUI will not stop these VMs; they will continue running in the background.\nTo stop them, shut them down in TartUI first or use `tart stop` later.",
      running.joined(separator: ", ")
    )
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.text("Quit Anyway"))
    alert.addButton(withTitle: L10n.text("Cancel"))

    return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
