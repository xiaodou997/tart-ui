import Foundation
import Observation
import TartKit

/// 一次虚拟机运行会话。
@Observable
@MainActor
final class RunSession: Identifiable {
  enum State: Equatable {
    /// 已发出启动命令，还没看到任何输出。
    case starting
    /// 正在运行。
    case running
    /// 进程已退出。`code` 为 0 表示正常关闭。
    case exited(code: Int32)
    /// 启动失败（二进制找不到、参数非法等），带上原因。
    case failed(reason: String)

    var isActive: Bool {
      switch self {
      case .starting, .running: true
      case .exited, .failed: false
      }
    }
  }

  let id = UUID()
  let vmName: String
  let profileName: String
  let startedAt: Date
  /// 实际执行的完整命令，展示在日志顶部，方便用户复制到终端复现。
  let commandLine: String

  private(set) var state: State = .starting
  private(set) var endedAt: Date?

  /// 内存中保留的最近日志。
  ///
  /// 有上限是必须的：虚拟机可能连续跑几天，全量留在内存里迟早撑爆。
  /// 完整日志另行写入文件。
  private(set) var recentLines: [LogLine] = []
  private let maxRetainedLines = 2000

  /// 完整日志的落盘位置。
  let logFileURL: URL?

  private var logHandle: FileHandle?

  init(vmName: String, profileName: String, commandLine: String, logFileURL: URL?) {
    self.vmName = vmName
    self.profileName = profileName
    self.startedAt = Date()
    self.commandLine = commandLine
    self.logFileURL = logFileURL

    if let logFileURL {
      logHandle = Self.openLogFile(at: logFileURL, header: commandLine)
    }
  }

  // MARK: - 状态更新

  func markRunning() {
    guard state == .starting else { return }
    state = .running
  }

  func append(_ line: String, isError: Bool) {
    markRunning()

    let entry = LogLine(text: line, isError: isError)
    recentLines.append(entry)
    // 超出上限就从头丢弃，保留最近的内容。
    if recentLines.count > maxRetainedLines {
      recentLines.removeFirst(recentLines.count - maxRetainedLines)
    }

    writeToFile(entry)
  }

  func markExited(code: Int32) {
    guard state.isActive else { return }
    state = .exited(code: code)
    endedAt = Date()
    closeLogFile(footer: "进程退出，退出码 \(code)")
  }

  func markFailed(reason: String) {
    guard state.isActive else { return }
    state = .failed(reason: reason)
    endedAt = Date()
    closeLogFile(footer: "启动失败：\(reason)")
  }

  // MARK: - 日志文件

  private static func openLogFile(at url: URL, header: String) -> FileHandle? {
    let fileManager = FileManager.default
    do {
      try fileManager.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      fileManager.createFile(atPath: url.path, contents: nil)
      let handle = try FileHandle(forWritingTo: url)
      let banner = "$ \(header)\n\n"
      try handle.write(contentsOf: Data(banner.utf8))
      return handle
    } catch {
      // 日志写不了不该影响虚拟机启动，降级为只在内存里保留。
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
