import Foundation
import Observation
import TartKit

/// 一次长时后台操作（创建、克隆、拉取镜像等）。
@Observable
@MainActor
final class BackgroundOperation: Identifiable {
  enum State: Equatable {
    case running
    case succeeded
    case failed(reason: String)
    case cancelled

    var isFinished: Bool {
      if case .running = self { return false }
      return true
    }
  }

  let id = UUID()
  /// 展示给用户的标题，如「克隆 base → dev」。
  let title: String
  let startedAt = Date()

  private(set) var state: State = .running
  private(set) var endedAt: Date?

  /// 最近的输出行。长任务可能刷出大量进度，这里同样要限量。
  private(set) var recentLines: [String] = []
  private let maxRetainedLines = 500

  /// 最后一行输出，用于在紧凑的状态条上显示当前进展。
  var latestLine: String? { recentLines.last }

  init(title: String) {
    self.title = title
  }

  func append(_ line: String) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    recentLines.append(trimmed)
    if recentLines.count > maxRetainedLines {
      recentLines.removeFirst(recentLines.count - maxRetainedLines)
    }
  }

  func finish(state: State) {
    guard !self.state.isFinished else { return }
    self.state = state
    endedAt = Date()
  }

  var duration: TimeInterval {
    (endedAt ?? Date()).timeIntervalSince(startedAt)
  }
}

/// 管理所有后台长时操作。
@Observable
@MainActor
final class OperationCenter {
  private(set) var operations: [BackgroundOperation] = []
  private var tasks: [UUID: Task<Void, Never>] = [:]

  var activeOperations: [BackgroundOperation] {
    operations.filter { !$0.state.isFinished }
  }

  var hasActiveWork: Bool { !activeOperations.isEmpty }

  /// 跑一条流式命令，把输出汇集到一个可展示的操作对象上。
  ///
  /// - Parameter onSuccess: 成功后在主线程执行，通常用来刷新列表。
  @discardableResult
  func run(
    title: String,
    stream: @escaping @Sendable () -> AsyncThrowingStream<CommandEvent, any Error>,
    onSuccess: @escaping @MainActor () async -> Void = {}
  ) -> BackgroundOperation {
    let operation = BackgroundOperation(title: title)
    operations.append(operation)

    tasks[operation.id] = Task { [weak self] in
      var exitCode: Int32 = 0

      do {
        for try await event in stream() {
          switch event {
          case .started:
            break
          case let .stdout(line):
            operation.append(line)
          case let .stderr(line):
            // tart 把进度信息写在 stderr 上，不能一见 stderr 就判定为失败。
            operation.append(line)
          case let .exited(code):
            exitCode = code
          }
        }

        if Task.isCancelled {
          operation.finish(state: .cancelled)
        } else if exitCode == 0 {
          operation.finish(state: .succeeded)
          await onSuccess()
        } else {
          // 失败原因通常就在最后几行输出里。
          let tail = operation.recentLines.suffix(3).joined(separator: "\n")
          operation.finish(state: .failed(reason: tail.isEmpty ? L10n.format("Exit code %@", String(exitCode)) : tail))
        }
      } catch {
        operation.finish(state: .failed(reason: error.localizedDescription))
      }

      self?.tasks.removeValue(forKey: operation.id)
    }

    return operation
  }

  /// 中止一个正在进行的操作。
  ///
  /// 取消会终止子进程。对 clone 这类操作，tart 可能已经写入了部分数据，
  /// 界面上需要提示用户可能留下未完成的虚拟机。
  func cancel(_ operation: BackgroundOperation) {
    tasks[operation.id]?.cancel()
    operation.finish(state: .cancelled)
  }

  func dismiss(_ operation: BackgroundOperation) {
    guard operation.state.isFinished else { return }
    operations.removeAll { $0.id == operation.id }
  }

  /// 清掉所有已结束的操作记录。
  func clearFinished() {
    operations.removeAll { $0.state.isFinished }
  }
}
