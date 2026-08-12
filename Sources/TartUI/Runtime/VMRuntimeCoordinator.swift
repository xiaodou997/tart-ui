import Foundation
import Observation
import TartKit
import TartVMCore

/// TartUI 的虚拟机运行时协调器。
///
/// 虚拟机在 TartUI 进程内运行：这里持有 `TartVirtualMachine`，启动、关机、
/// 挂起都是直接的方法调用。之前那套「起子进程 → 解析 stdout → 发信号 →
/// 靠退出码反推结果」的链路整个消失了，随之消失的还有它的失败模式——
/// 窗口事件再也不可能把虚拟机关掉。
///
/// OCI 相关操作（pull / clone / push / list）仍然走 tart 命令行子进程。
/// 那些是一次性命令，进程模型对它们是合适的。
@Observable
@MainActor
final class VMRuntimeCoordinator {
  private(set) var sessions: [String: VMRuntimeSession] = [:]
  private(set) var finishedSessions: [VMRuntimeSession] = []

  /// 正在运行的虚拟机对象，按虚拟机名索引。窗口通过这里拿到要渲染的对象。
  private(set) var machines: [String: TartVirtualMachine] = [:]

  private var tasks: [String: Task<Void, Never>] = [:]
  private let onSessionFinished: @MainActor @Sendable (VMRuntimeSession) -> Void

  /// 请求打开某台虚拟机的窗口。由 App 层接上 SwiftUI 的 openWindow。
  var onWindowRequested: (@MainActor @Sendable (String) -> Void)?

  init(onSessionFinished: @escaping @MainActor @Sendable (VMRuntimeSession) -> Void = { _ in }) {
    self.onSessionFinished = onSessionFinished
  }

  // MARK: - 查询

  func session(for vmName: String) -> VMRuntimeSession? {
    sessions[vmName]
  }

  func machine(for vmName: String) -> TartVirtualMachine? {
    machines[vmName]
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
      // 已经在跑就只把窗口叫到前面，不重复启动。
      showWindow(vmName: vmName)
      return existing
    }

    let session = VMRuntimeSession(
      vmName: vmName,
      profileName: profile.name,
      equivalentCommandLine: "tart " + profile.arguments(vmName: vmName).joined(separator: " "),
      capturesSystemKeys: profile.captureSystemKeys,
      logFileURL: Self.logFileURL(for: vmName)
    )
    sessions[vmName] = session

    tasks[vmName] = Task { [weak self] in
      await self?.run(session: session, vmName: vmName, profile: profile)
    }

    return session
  }

  private func run(session: VMRuntimeSession, vmName: String, profile: RunProfile) async {
    let machine: TartVirtualMachine
    do {
      machine = try TartVirtualMachine(
        localVMNamed: vmName,
        options: profile.tartVMOptions()
      )
    } catch {
      session.markFailed(error: error)
      retire(vmName: vmName)
      return
    }

    machines[vmName] = machine
    let wasSuspended = machine.hasSuspendedState

    do {
      try await machine.start(recovery: profile.recovery)
    } catch {
      session.markFailed(error: error)
      retire(vmName: vmName)
      return
    }

    if wasSuspended {
      session.markResumedFromSuspend()
    } else {
      session.markRunning()
    }

    // 窗口在虚拟机确实起来之后才打开。开得太早会先闪一个黑框，
    // 但更重要的是：现在窗口的开与关跟虚拟机生命周期完全无关，
    // 顺序只影响观感，不影响正确性。
    if !profile.noGraphics {
      onWindowRequested?(vmName)
    }

    do {
      // 一直挂起到客户机自己停下来（关机、崩溃、或我们调用了 stop）。
      try await machine.waitUntilStopped()
      if session.state != .suspending {
        session.markExited()
      }
    } catch is CancellationError {
      session.markExited()
    } catch {
      session.markFailed(error: error)
    }

    retire(vmName: vmName)
  }

  private func retire(vmName: String) {
    guard let session = sessions[vmName], !session.state.isActive else { return }
    tasks.removeValue(forKey: vmName)
    machines.removeValue(forKey: vmName)
    finishedSessions.append(session)

    if finishedSessions.count > 20 {
      finishedSessions.removeFirst(finishedSessions.count - 20)
    }
    onSessionFinished(session)
  }

  // MARK: - 停止

  /// 请求客户机正常关机。
  ///
  /// 客户机可以拒绝（比如有未保存的文档弹了确认框），所以这个方法返回
  /// 不代表已经关机；真正结束时 `run` 里的 `waitUntilStopped()` 会返回。
  func stop(vmName: String, timeout: UInt? = nil) async throws {
    guard let machine = machines[vmName], let session = sessions[vmName] else { return }
    session.markStopping()

    do {
      try machine.requestStop()
    } catch {
      session.markRunning()
      throw error
    }
  }

  /// 把状态存盘并停机。下次启动会自动从该状态恢复。
  func suspend(vmName: String) async throws {
    guard let machine = machines[vmName], let session = sessions[vmName] else { return }
    session.markSuspending()

    do {
      try await machine.suspendToDisk()
      session.markSuspended()
    } catch {
      session.markFailed(error: error)
      throw error
    }
  }

  /// 在应用退出前把所有虚拟机停稳。
  ///
  /// 顺序是有意的：能挂起就挂起（状态存盘，下次启动原样恢复），挂不了才
  /// 断电。直接让进程退出等于对每台虚拟机拔电源，而客户机被反复硬断电会
  /// 损坏它自己的文件系统——这不是假设，本项目就是这么弄坏过一台虚拟机的。
  func shutdownAll() async {
    let names = activeVMNames
    guard !names.isEmpty else { return }

    // 顺序停：退出路径上并发没有意义，而且同时写多台虚拟机的状态文件只会
    // 让磁盘更慢，反而拉长了「进程可能被强杀」的危险窗口。
    for vmName in names {
      guard let machine = machines[vmName] else { continue }
      let session = sessions[vmName]

      do {
        // 挂起要求虚拟机是 suspendable 配置；不满足时会抛错，走下面的兜底。
        session?.markSuspending()
        try await machine.suspendToDisk()
        session?.markSuspended()
      } catch {
        // 退而求其次：VZ 层面的干净停止仍会把磁盘缓冲刷干净，
        // 比进程被杀掉安全得多。
        try? await machine.stopImmediately()
        session?.markExited()
      }
      retire(vmName: vmName)
    }
  }

  /// 立即断电。未保存的数据会丢失。
  func forceTerminate(vmName: String) {
    guard let machine = machines[vmName] else { return }
    Task { [weak self] in
      try? await machine.stopImmediately()
      self?.sessions[vmName]?.markExited()
      self?.retire(vmName: vmName)
    }
  }

  @discardableResult
  func showWindow(vmName: String) -> Bool {
    guard let session = sessions[vmName], session.state.isActive else { return false }
    onWindowRequested?(vmName)
    return true
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
