import Foundation
import Observation

/// 一次由 TartUI 管理的虚拟机运行会话。
///
/// 虚拟机跑在 TartUI 进程内，所以会话不再有子进程 PID，也不再靠解析
/// stdout 猜状态：每次状态变化都由一次明确的方法调用推动。
///
/// 「等待窗口」这个状态也一并消失了。窗口由 TartUI 自己创建，不存在
/// 「虚拟机起来了但窗口没出现」的中间态，更不存在窗口事件反过来把
/// 虚拟机关掉的可能。
@Observable
@MainActor
final class VMRuntimeSession: Identifiable {
  enum State: Equatable {
    case starting
    case running
    case stopping
    case suspending
    /// 已挂起，状态存在磁盘上，下次启动会自动恢复。
    case suspended
    case exited
    case failed(VMRuntimeFailure)

    var isActive: Bool {
      switch self {
      case .starting, .running, .stopping, .suspending: true
      case .suspended, .exited, .failed: false
      }
    }
  }

  let id = UUID()
  let vmName: String
  let profileName: String
  let startedAt: Date
  let logFileURL: URL?

  /// 是否把 Cmd+Tab 这类系统快捷键送进客户机。
  ///
  /// 记在会话上而不是事后去查 profile：profile 可能在虚拟机运行期间被改，
  /// 而窗口的行为应该跟着这次启动时的设置走。
  let capturesSystemKeys: Bool

  /// 与本次启动等效的 tart 命令行，只用于展示和排查。
  ///
  /// TartUI 不再执行它——虚拟机是进程内起的——但把它显示出来，用户就能
  /// 在终端复现同一次启动，这在报 bug 时很有用。
  let equivalentCommandLine: String

  private(set) var state: State = .starting
  private(set) var endedAt: Date?
  private(set) var recentLines: [LogLine] = []

  private let maxRetainedLines = 2000
  private var logHandle: FileHandle?

  init(
    vmName: String,
    profileName: String,
    equivalentCommandLine: String,
    capturesSystemKeys: Bool,
    logFileURL: URL?
  ) {
    self.vmName = vmName
    self.profileName = profileName
    self.startedAt = Date()
    self.equivalentCommandLine = equivalentCommandLine
    self.capturesSystemKeys = capturesSystemKeys
    self.logFileURL = logFileURL

    if let logFileURL {
      logHandle = Self.openLogFile(at: logFileURL)
    }
    appendLifecycle("$ \(equivalentCommandLine)")
    appendLifecycle(L10n.text("Starting the virtual machine…"))
  }

  // MARK: - 状态

  func markRunning() {
    guard state == .starting else { return }
    state = .running
    appendLifecycle(L10n.text("The virtual machine is running."))
  }

  func markResumedFromSuspend() {
    guard state == .starting else { return }
    state = .running
    appendLifecycle(L10n.text("Resumed from the suspended state."))
  }

  /// 客户机自行重启了一次。
  ///
  /// 虚拟机本身没有停止，所以状态不变；但这件事必须留下痕迹——它在界面上
  /// 原本完全不可见，只能靠盯着画面才知道客户机在反复回到开机画面。
  private(set) var guestRestartCount = 0

  func markGuestRestarted(count: Int) {
    guard state.isActive else { return }
    guestRestartCount = count
    appendLifecycle(L10n.format(
      "The guest restarted itself (%@ times). If this keeps repeating, the guest is failing to boot.",
      String(count)
    ))
  }

  func markStopping() {
    guard state == .running else { return }
    state = .stopping
    appendLifecycle(L10n.text("Asking the guest to shut down…"))
  }

  func markSuspending() {
    guard state == .running else { return }
    state = .suspending
    appendLifecycle(L10n.text("Saving the virtual machine state…"))
  }

  func markSuspended() {
    guard state.isActive else { return }
    state = .suspended
    endedAt = Date()
    appendLifecycle(L10n.text("The virtual machine is suspended."))
    closeLogFile()
  }

  func markExited() {
    guard state.isActive else { return }
    state = .exited
    endedAt = Date()
    appendLifecycle(L10n.text("The virtual machine has stopped."))
    closeLogFile()
  }

  func markFailed(error: any Error) {
    markFailed(failure: VMRuntimeFailure(error: error))
  }

  func markFailed(failure: VMRuntimeFailure) {
    guard state.isActive else { return }
    state = .failed(failure)
    endedAt = Date()
    appendLifecycle(L10n.format("Start failed: %@", failure.message))
    closeLogFile()
  }

  // MARK: - 日志

  func append(_ line: String, isError: Bool) {
    append(LogLine(text: line, isError: isError, isLifecycle: false))
  }

  private func appendLifecycle(_ line: String) {
    append(LogLine(text: line, isError: false, isLifecycle: true))
  }

  private func append(_ entry: LogLine) {
    recentLines.append(entry)
    if recentLines.count > maxRetainedLines {
      recentLines.removeFirst(recentLines.count - maxRetainedLines)
    }

    writeToFile(entry)
  }

  private static func openLogFile(at url: URL) -> FileHandle? {
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      fileManager.createFile(atPath: url.path, contents: nil)
      return try FileHandle(forWritingTo: url)
    } catch {
      // 日志写不了不应阻止虚拟机启动，降级为只保留内存日志。
      return nil
    }
  }

  private func writeToFile(_ line: LogLine) {
    guard let logHandle else { return }
    let prefix = line.isError ? "[err] " : line.isLifecycle ? "[TartUI] " : ""
    try? logHandle.write(contentsOf: Data("\(prefix)\(line.text)\n".utf8))
  }

  private func closeLogFile() {
    guard let logHandle else { return }
    try? logHandle.close()
    self.logHandle = nil
  }
}

struct LogLine: Identifiable, Hashable {
  let id = UUID()
  let text: String
  let isError: Bool
  let isLifecycle: Bool
  let timestamp = Date()
}
