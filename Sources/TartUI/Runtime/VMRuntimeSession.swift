import Foundation
import Observation

/// 一次由 TartUI 管理的虚拟机运行会话。
///
/// 会话只保存状态、启动计划和日志；进程的启动与停止由
/// VMRuntimeCoordinator 负责，显示行为由 VMDisplayDriver 描述。
@Observable
@MainActor
final class VMRuntimeSession: Identifiable {
  enum State: Equatable {
    case starting
    case waitingForWindow
    case running
    case stopping
    case exited(code: Int32)
    case failed(VMRuntimeFailure)

    var isActive: Bool {
      switch self {
      case .starting, .waitingForWindow, .running, .stopping: true
      case .exited, .failed: false
      }
    }
  }

  let id = UUID()
  let vmName: String
  let profileName: String
  let startedAt: Date
  let launchPlan: VMRuntimeLaunchPlan
  let logFileURL: URL?

  var commandLine: String { launchPlan.commandLine }
  var displayMode: VMDisplayMode { launchPlan.displayMode }
  var displayDriverOwnsWindow: Bool { displayMode == .nativeWindow }

  private(set) var state: State = .starting
  private(set) var endedAt: Date?
  private(set) var recentLines: [LogLine] = []
  private(set) var processIdentifier: Int32?
  private(set) var isWindowReady = false
  private(set) var windowWarning: String?

  private let maxRetainedLines = 2000
  private var logHandle: FileHandle?

  init(launchPlan: VMRuntimeLaunchPlan, logFileURL: URL?) {
    self.vmName = launchPlan.vmName
    self.profileName = launchPlan.profileName
    self.startedAt = Date()
    self.launchPlan = launchPlan
    self.logFileURL = logFileURL

    if let logFileURL {
      logHandle = Self.openLogFile(at: logFileURL)
    }
    appendLifecycle("$ \(launchPlan.commandLine)")
    appendLifecycle(L10n.text("Preparing Tart runtime…"))
  }

  // MARK: - 状态

  func markProcessStarted(processIdentifier: Int32) {
    guard state.isActive else { return }
    self.processIdentifier = processIdentifier
    appendLifecycle(L10n.format("Tart runtime started (PID %@).", String(processIdentifier)))

    if displayDriverOwnsWindow, !isWindowReady {
      state = .waitingForWindow
      appendLifecycle(L10n.text("Waiting for the VM window…"))
    } else if state != .stopping {
      markRunning()
    }
  }

  func markRunning() {
    guard state == .starting || state == .waitingForWindow || state == .stopping else { return }
    state = .running
  }

  func markWindowReady() {
    guard state.isActive else { return }
    isWindowReady = true
    windowWarning = nil
    if state != .stopping {
      state = .running
    }
    appendLifecycle(L10n.text("VM window is ready."))
  }

  func markWindowWaitTimedOut() {
    guard state == .waitingForWindow else { return }
    let message = L10n.text("The VM is running without a visible window. Use Show VM Window to bring it forward.")
    state = .running
    windowWarning = message
    appendLifecycle(message)
  }

  func markStopping() {
    guard state.isActive else { return }
    state = .stopping
  }

  func append(_ line: String, isError: Bool) {
    let entry = LogLine(text: line, isError: isError, isLifecycle: false)
    append(entry)
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

  func markExited(code: Int32) {
    guard state.isActive else { return }
    state = .exited(code: code)
    endedAt = Date()
    appendLifecycle(L10n.format("Process exited with code %@", String(code)))
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
