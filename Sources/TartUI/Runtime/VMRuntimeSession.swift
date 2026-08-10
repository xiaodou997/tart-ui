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
    case running
    case stopping
    case exited(code: Int32)
    case failed(VMRuntimeFailure)

    var isActive: Bool {
      switch self {
      case .starting, .running, .stopping: true
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

  private let maxRetainedLines = 2000
  private var logHandle: FileHandle?

  init(launchPlan: VMRuntimeLaunchPlan, logFileURL: URL?) {
    self.vmName = launchPlan.vmName
    self.profileName = launchPlan.profileName
    self.startedAt = Date()
    self.launchPlan = launchPlan
    self.logFileURL = logFileURL

    if let logFileURL {
      logHandle = Self.openLogFile(at: logFileURL, header: launchPlan.commandLine)
    }
  }

  // MARK: - 状态

  func markRunning() {
    guard state == .starting || state == .stopping else { return }
    state = .running
  }

  func markStopping() {
    guard state.isActive else { return }
    state = .stopping
  }

  func append(_ line: String, isError: Bool) {
    // Tart 会在真正显示窗口或网络初始化前输出若干行日志；收到输出只说明
    // 进程已经启动，不应把 stopping 状态重新改回 running。
    if state == .starting {
      state = .running
    }

    let entry = LogLine(text: line, isError: isError)
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
    closeLogFile(footer: L10n.format("Process exited with code %@", String(code)))
  }

  func markFailed(error: any Error) {
    markFailed(failure: VMRuntimeFailure(error: error))
  }

  func markFailed(failure: VMRuntimeFailure) {
    guard state.isActive else { return }
    state = .failed(failure)
    endedAt = Date()
    closeLogFile(footer: L10n.format("Start failed: %@", failure.message))
  }

  // MARK: - 日志

  private static func openLogFile(at url: URL, header: String) -> FileHandle? {
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      fileManager.createFile(atPath: url.path, contents: nil)
      let handle = try FileHandle(forWritingTo: url)
      try handle.write(contentsOf: Data("$ \(header)\n\n".utf8))
      return handle
    } catch {
      // 日志写不了不应阻止虚拟机启动，降级为只保留内存日志。
      return nil
    }
  }

  private func writeToFile(_ line: LogLine) {
    guard let logHandle else { return }
    let prefix = line.isError ? "[err] " : ""
    try? logHandle.write(contentsOf: Data("\(prefix)\(line.text)\n".utf8))
  }

  private func closeLogFile(footer: String) {
    guard let logHandle else { return }
    try? logHandle.write(contentsOf: Data("\n\(footer)\n".utf8))
    try? logHandle.close()
    self.logHandle = nil
  }
}

struct LogLine: Identifiable, Hashable {
  let id = UUID()
  let text: String
  let isError: Bool
  let timestamp = Date()
}
