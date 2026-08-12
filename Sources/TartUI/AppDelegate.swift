import AppKit

/// 应用退出时的虚拟机保护。
///
/// 虚拟机跑在 TartUI 进程内，所以「TartUI 退出」就等于「所有虚拟机断电」。
/// 这和子进程时代的语义完全相反——那时候 helper 会被移交给 launchd 继续跑，
/// 退出 App 不影响虚拟机。
///
/// 这个区别很要命：客户机被反复硬断电会真的损坏它的文件系统。所以这里的
/// 每一条路径都必须先让虚拟机停稳，再让进程退出。
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// 由 App 在启动时注入，返回当前由 TartUI 管理的运行中虚拟机名称。
  ///
  /// AppDelegate 拿不到 SwiftUI 的 @State，只能用这种方式取数据。
  @MainActor static var runningVMNamesProvider: (() -> [String])?

  /// 停稳所有运行中的虚拟机。返回后进程才可以安全退出。
  @MainActor static var shutdownAllVMs: (() async -> Void)?

  private var signalSources: [DispatchSourceSignal] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    installSignalHandlers()
  }

  // MARK: - 退出

  @MainActor
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let running = Self.runningVMNamesProvider?() ?? []
    guard !running.isEmpty else { return .terminateNow }

    let alert = NSAlert()
    alert.messageText = L10n.format("%@ VM(s) are still running", String(running.count))
    alert.informativeText = L10n.format(
      "%@\n\nQuitting TartUI will shut down these VMs, because they run inside this app. Unsaved work in the guest may be lost.",
      running.joined(separator: ", ")
    )
    alert.alertStyle = .warning
    alert.addButton(withTitle: L10n.text("Shut Down and Quit"))
    alert.addButton(withTitle: L10n.text("Cancel"))

    guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }

    // 先把虚拟机停稳再退出。直接 terminateNow 等同于拔电源。
    Task { @MainActor in
      await Self.shutdownAllVMs?()
      NSApplication.shared.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }

  /// 关掉最后一个窗口不退出应用。
  ///
  /// 虚拟机窗口是可以随手关掉的——虚拟机会在后台继续运行。如果这里返回
  /// true，关掉窗口就会让进程退出，虚拟机随之断电，等于把「关闭窗口」
  /// 变成了「拔电源」。
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  // MARK: - 信号

  /// 捕获 SIGINT / SIGTERM，先停虚拟机再退出。
  ///
  /// 这条路径不是理论风险：`tart stop <name>` 的实现就是朝持有虚拟机目录锁
  /// 的进程发 SIGINT。上游那个进程只管一台虚拟机，被杀掉正是预期行为；
  /// 但在 TartUI 里，同一个进程管着所有虚拟机，默认处理会把它们一起硬断电。
  private func installSignalHandlers() {
    for signalNumber in [SIGINT, SIGTERM] {
      // 必须先忽略默认处理，否则进程在 DispatchSource 收到之前就没了。
      signal(signalNumber, SIG_IGN)

      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
      source.setEventHandler {
        Task { @MainActor in
          await Self.shutdownAllVMs?()
          NSApplication.shared.terminate(nil)
        }
      }
      source.activate()
      signalSources.append(source)
    }
  }
}
