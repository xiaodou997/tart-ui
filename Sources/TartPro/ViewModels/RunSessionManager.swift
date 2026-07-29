import Foundation
import Observation
import TartKit

/// 管理由 TartPro 启动的虚拟机进程。
///
/// 注意这里只掌握「自己启动的」那些。用户也可能在终端里直接 `tart run`，
/// 那些虚拟机在列表里同样显示为运行中，但 TartPro 没有它们的进程句柄——
/// 只能通过 `tart stop` 请求关闭，不能强制结束。界面上必须如实区分这两种情况。
@Observable
@MainActor
final class RunSessionManager {
  /// 虚拟机名 → 当前会话。
  private(set) var sessions: [String: RunSession] = [:]

  /// 已结束但用户还没关掉的会话，保留下来是为了能查看失败原因和日志。
  private(set) var finishedSessions: [RunSession] = []

  private var tasks: [String: Task<Void, Never>] = [:]
  private let client: TartClient

  init(client: TartClient) {
    self.client = client
  }

  // MARK: - 查询

  func session(for vmName: String) -> RunSession? {
    sessions[vmName]
  }

  /// TartPro 是否掌握着这台虚拟机的进程。
  func isManaged(_ vmName: String) -> Bool {
    sessions[vmName]?.state.isActive ?? false
  }

  var activeCount: Int {
    sessions.values.count { $0.state.isActive }
  }

  // MARK: - 启动

  /// 启动虚拟机。
  ///
  /// 立即返回，不等虚拟机真正开机——`tart run` 会一直运行到虚拟机关闭。
  @discardableResult
  func start(vmName: String, profile: RunProfile) -> RunSession {
    // 已经在跑就直接返回现有会话，避免重复启动同一台虚拟机。
    if let existing = sessions[vmName], existing.state.isActive {
      return existing
    }

    let arguments = profile.arguments(vmName: vmName)
    let session = RunSession(
      vmName: vmName,
      profileName: profile.name,
      commandLine: "tart " + arguments.joined(separator: " "),
      logFileURL: Self.logFileURL(for: vmName)
    )
    sessions[vmName] = session

    // Task 挂在 manager 上而不是某个视图上：绑定到视图的话，
    // 用户切走导致视图销毁时 Task 被取消，会连带杀掉虚拟机。
    tasks[vmName] = Task { [weak self] in
      await self?.pump(session: session, vmName: vmName, profile: profile)
    }

    return session
  }

  /// 消费 tart 的输出流直到进程结束。
  private func pump(session: RunSession, vmName: String, profile: RunProfile) async {
    do {
      for try await event in client.runVM(name: vmName, profile: profile) {
        switch event {
        case let .stdout(line):
          session.append(line, isError: false)
        case let .stderr(line):
          // tart 把正常的进度信息也写在 stderr 上，
          // 所以这里不能一见 stderr 就判定为出错。
          session.append(line, isError: true)
        case let .exited(code):
          session.markExited(code: code)
        }
      }
      // 流正常结束但没收到退出事件，按正常退出处理。
      if session.state.isActive {
        session.markExited(code: 0)
      }
    } catch {
      session.markFailed(reason: error.localizedDescription)
    }

    retire(vmName: vmName)
  }

  private func retire(vmName: String) {
    guard let session = sessions[vmName], !session.state.isActive else { return }
    sessions.removeValue(forKey: vmName)
    tasks.removeValue(forKey: vmName)
    finishedSessions.append(session)
    // 只留最近若干条结束记录，避免长期运行后无限增长。
    if finishedSessions.count > 20 {
      finishedSessions.removeFirst(finishedSessions.count - 20)
    }
  }

  // MARK: - 停止

  /// 请求虚拟机关机。
  ///
  /// 走 `tart stop` 而不是直接杀进程：前者会通知客户机正常关机，
  /// 直接杀等同于拔电源，有丢数据的风险。
  func stop(vmName: String, timeout: UInt? = nil) async throws {
    try await client.stop(name: vmName, timeout: timeout)
  }

  func suspend(vmName: String) async throws {
    try await client.suspend(name: vmName)
  }

  /// 强制终止进程，等同于拔电源。
  ///
  /// 仅在 `tart stop` 无响应时作为兜底，且只对 TartPro 自己启动的虚拟机有效。
  func forceTerminate(vmName: String) {
    tasks[vmName]?.cancel()
  }

  func dismissFinished(_ session: RunSession) {
    finishedSessions.removeAll { $0.id == session.id }
  }

  // MARK: - 日志位置

  private static func logFileURL(for vmName: String) -> URL? {
    guard let base = try? FileManager.default.url(
      for: .libraryDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: false
    ) else { return nil }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    // 虚拟机名可能含斜杠（OCI 引用），不能直接当文件名。
    let safeName = vmName.replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")

    return base
      .appendingPathComponent("Logs/TartPro", isDirectory: true)
      .appendingPathComponent("\(safeName)-\(formatter.string(from: Date())).log")
  }
}
