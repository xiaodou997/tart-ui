import AppKit

/// TartUI 的显示生命周期协调器。
///
/// 第一阶段的原生窗口仍由 Tart helper 创建；TartUI 负责作为唯一用户应用
/// 保持前台，并记录显示驱动。后续嵌入式 VNC 驱动可以在这里接管窗口，而不
/// 需要改变 VMRuntimeCoordinator 的进程和状态管理。
@MainActor
final class VMDisplayCoordinator {
  private(set) var activeModes: [String: VMDisplayMode] = [:]

  func sessionDidStart(_ session: VMRuntimeSession) {
    activeModes[session.vmName] = session.displayMode

    // 原生窗口由 Agent helper 创建，但用户操作的应用身份属于 TartUI。
    // 激活外层应用可以避免启动后焦点停留在 Finder 或终端。
    if session.displayDriverOwnsWindow {
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  func sessionDidFinish(_ session: VMRuntimeSession) {
    activeModes.removeValue(forKey: session.vmName)
  }
}
