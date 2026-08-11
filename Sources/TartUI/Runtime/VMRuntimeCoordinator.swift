import Foundation
import Observation
import TartKit

/// TartUI 的虚拟机运行时协调器。
///
/// 它是 UI 与 Tart 子进程之间唯一的生命周期边界：
/// - UI 只提交启动计划；
/// - 运行时服务负责执行 Tart；
/// - 会话负责状态和日志；
/// - 显示协调器负责窗口/显示驱动生命周期。
@Observable
@MainActor
final class VMRuntimeCoordinator {
  private(set) var sessions: [String: VMRuntimeSession] = [:]
  private(set) var finishedSessions: [VMRuntimeSession] = []

  private var tasks: [String: Task<Void, Never>] = [:]
  private var windowTimeoutTasks: [String: Task<Void, Never>] = [:]
  private let runtime: any VMRuntimeService
  private let displayCoordinator: VMDisplayCoordinator
  private let onSessionFinished: @MainActor @Sendable (VMRuntimeSession) -> Void

  private static let windowReadyMarker = "TARTUI_EVENT:window-ready"

  init(
    runtime: any VMRuntimeService,
    displayCoordinator: VMDisplayCoordinator = VMDisplayCoordinator(),
    onSessionFinished: @escaping @MainActor @Sendable (VMRuntimeSession) -> Void = { _ in }
  ) {
    self.runtime = runtime
    self.displayCoordinator = displayCoordinator
    self.onSessionFinished = onSessionFinished
  }

  // MARK: - 查询

  func session(for vmName: String) -> VMRuntimeSession? {
    sessions[vmName]
  }

  func isManaged(_ vmName: String) -> Bool {
    sessions[vmName]?.state.isActive ?? false
  }

  var activeCount: Int {
    sessions.values.count { $0.state.isActive }
  }

  var activeVMNames: [String] {
    sessions.values.filter { $0.state.isActive }.map(\.vmName).sorted()
  }

  // MARK: - 启动

  @discardableResult
  func start(vmName: String, profile: RunProfile) -> VMRuntimeSession {
    if let existing = sessions[vmName], existing.state.isActive {
      return existing
    }

    let driver = TartDisplayDriver.forProfile(profile)
    let plan = driver.makeLaunchPlan(vmName: vmName, profile: profile)
    let session = VMRuntimeSession(
      launchPlan: plan,
      logFileURL: Self.logFileURL(for: vmName)
    )
    sessions[vmName] = session
    displayCoordinator.sessionDidStart(session)

    tasks[vmName] = Task { [weak self] in
      await self?.pump(session: session, plan: plan, vmName: vmName)
    }

    return session
  }

  private func pump(
    session: VMRuntimeSession,
    plan: VMRuntimeLaunchPlan,
    vmName: String
  ) async {
    do {
      for try await event in runtime.start(plan: plan) {
        switch event {
        case let .started(processIdentifier):
          session.markProcessStarted(processIdentifier: processIdentifier)
          if session.displayDriverOwnsWindow, !session.isWindowReady {
            scheduleWindowTimeout(for: session, vmName: vmName)
          }
        case let .stdout(line):
          if session.state == .starting { session.markRunning() }
          session.append(line, isError: false)
        case let .stderr(line):
          if line == Self.windowReadyMarker {
            windowTimeoutTasks.removeValue(forKey: vmName)?.cancel()
            session.markWindowReady()
            displayCoordinator.sessionWindowDidBecomeReady(session)
            continue
          }
          if session.state == .starting { session.markRunning() }
          // Tart 把正常的启动进度也写在 stderr 上，保留来源但不直接判定失败。
          session.append(line, isError: true)
        case let .exited(code):
          session.markExited(code: code)
        }
      }

      // 流正常结束但没有退出事件时，按正常退出处理。
      if session.state.isActive {
        session.markExited(code: 0)
      }
    } catch is CancellationError {
      // 取消由用户触发时，底层 TartExecutor 会终止子进程；如果没有收到退出事件，
      // 仍然把会话收束掉，避免 UI 永远停在 Starting。
      if session.state.isActive {
        session.markExited(code: 0)
      }
    } catch {
      session.markFailed(error: error)
    }

    retire(vmName: vmName)
  }

  private func retire(vmName: String) {
    guard let session = sessions[vmName], !session.state.isActive else { return }
    tasks.removeValue(forKey: vmName)
    windowTimeoutTasks.removeValue(forKey: vmName)?.cancel()
    displayCoordinator.sessionDidFinish(session)
    finishedSessions.append(session)

    if finishedSessions.count > 20 {
      finishedSessions.removeFirst(finishedSessions.count - 20)
    }
    onSessionFinished(session)
  }

  private func scheduleWindowTimeout(for session: VMRuntimeSession, vmName: String) {
    windowTimeoutTasks.removeValue(forKey: vmName)?.cancel()
    windowTimeoutTasks[vmName] = Task { @MainActor [weak session] in
      try? await Task.sleep(for: .seconds(8))
      guard !Task.isCancelled, let session else { return }
      session.markWindowWaitTimedOut()
    }
  }

  // MARK: - 停止

  /// 请求虚拟机正常关机；只有 TartUI 自己管理的会话才会进入 stopping 状态。
  func stop(vmName: String, timeout: UInt? = nil) async throws {
    let session = sessions[vmName]
    if session?.state.isActive == true {
      session?.markStopping()
    }

    do {
      try await runtime.stop(vmName: vmName, timeout: timeout)
    } catch {
      // stop 命令失败时恢复可重试状态，保留原始错误交给上层展示。
      if session?.state == .stopping {
        session?.markRunning()
      }
      throw error
    }
  }

  func suspend(vmName: String) async throws {
    try await runtime.suspend(vmName: vmName)
  }

  /// 强制终止 TartUI 自己启动的进程，等同于断电。
  func forceTerminate(vmName: String) {
    tasks[vmName]?.cancel()
  }

  @discardableResult
  func showWindow(vmName: String) -> Bool {
    guard let session = sessions[vmName], session.state.isActive else { return false }
    return displayCoordinator.bringWindowForward(session)
  }

  func dismissFinished(_ session: VMRuntimeSession) {
    finishedSessions.removeAll { $0.id == session.id }
  }

  // MARK: - 日志

  private static func logFileURL(for vmName: String) -> URL? {
    guard let base = try? FileManager.default.url(
      for: .libraryDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: false
    ) else { return nil }

    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let safeName = vmName
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")

    return base
      .appendingPathComponent("Logs/TartUI", isDirectory: true)
      .appendingPathComponent("\(safeName)-\(formatter.string(from: Date())).log")
  }
}
