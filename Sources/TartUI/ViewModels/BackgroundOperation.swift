import Foundation
import Observation
import TartKit

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

  enum OutputStream: String {
    case stdout
    case stderr
  }

  struct OutputLine: Identifiable {
    let id = UUID()
    let stream: OutputStream
    let text: String
  }

  let id = UUID()
  let title: String
  let action: CommandAction
  let isCancellable: Bool
  let startedAt = Date()

  private(set) var state: State = .running
  private(set) var endedAt: Date?
  private(set) var processIdentifier: Int32?
  private(set) var exitCode: Int32?
  private(set) var outputLines: [OutputLine] = []

  private let maxRetainedLines = 500

  init(title: String, action: CommandAction, isCancellable: Bool) {
    self.title = title
    self.action = action
    self.isCancellable = isCancellable
  }

  var latestLine: OutputLine? { outputLines.last }
  var stdoutLines: [String] { outputLines.filter { $0.stream == .stdout }.map(\.text) }
  var stderrLines: [String] { outputLines.filter { $0.stream == .stderr }.map(\.text) }

  func markStarted(processIdentifier: Int32) {
    self.processIdentifier = processIdentifier
  }

  func markExited(_ code: Int32) {
    exitCode = code
  }

  func append(_ text: String, stream: OutputStream) {
    let lines = text
      .split(whereSeparator: { $0.isNewline })
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }

    for line in lines {
      outputLines.append(OutputLine(stream: stream, text: line))
    }

    if outputLines.count > maxRetainedLines {
      outputLines.removeFirst(outputLines.count - maxRetainedLines)
    }
  }

  func capture(_ result: CommandResult) {
    markExited(result.exitCode)
    append(result.stdout, stream: .stdout)
    append(result.stderr, stream: .stderr)
  }

  func capture(_ error: any Error) {
    guard let tartError = error as? TartError else { return }

    switch tartError {
    case let .commandFailed(_, code, stderr):
      markExited(code)
      append(stderr, stream: .stderr)
    case let .decodingFailed(_, raw, _):
      append(raw, stream: .stdout)
    case .cancelled:
      break
    case .binaryNotFound, .binaryNotExecutable, .unsupportedVersion, .launchFailed:
      break
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

  func failureReason(defaultExitCode: Int32? = nil) -> String {
    let stderrTail = stderrLines.suffix(3).joined(separator: "\n")
    if !stderrTail.isEmpty { return stderrTail }

    let outputTail = outputLines.suffix(3).map(\.text).joined(separator: "\n")
    if !outputTail.isEmpty { return outputTail }

    if let code = exitCode ?? defaultExitCode {
      return L10n.format("Exit code %@", String(code))
    }

    return L10n.text("Command failed.")
  }
}

@Observable
@MainActor
final class OperationCenter {
  private(set) var operations: [BackgroundOperation] = []
  private var tasks: [UUID: Task<Void, Never>] = [:]

  var activeOperations: [BackgroundOperation] {
    operations.filter { !$0.state.isFinished }
  }

  var hasActiveWork: Bool { !activeOperations.isEmpty }

  @discardableResult
  func run(
    title: String,
    action: CommandAction,
    stream: @escaping @Sendable () -> AsyncThrowingStream<CommandEvent, any Error>,
    onSuccess: @escaping @MainActor () async -> Void = {}
  ) -> BackgroundOperation {
    let operation = BackgroundOperation(title: title, action: action, isCancellable: true)
    operations.append(operation)

    tasks[operation.id] = Task { [weak self] in
      do {
        for try await event in stream() {
          switch event {
          case let .started(processIdentifier):
            operation.markStarted(processIdentifier: processIdentifier)
          case let .stdout(line):
            operation.append(line, stream: .stdout)
          case let .stderr(line):
            operation.append(line, stream: .stderr)
          case let .exited(code):
            operation.markExited(code)
          }
        }

        if Task.isCancelled {
          operation.finish(state: .cancelled)
        } else if (operation.exitCode ?? 0) == 0 {
          operation.finish(state: .succeeded)
          await onSuccess()
        } else {
          operation.finish(state: .failed(reason: operation.failureReason()))
        }
      } catch {
        if Task.isCancelled {
          operation.finish(state: .cancelled)
        } else {
          operation.capture(error)
          operation.finish(state: .failed(reason: operation.failureReason()))
        }
      }

      self?.tasks.removeValue(forKey: operation.id)
    }

    return operation
  }

  @discardableResult
  func perform(
    title: String,
    action: CommandAction,
    execute: @escaping @Sendable () async throws -> CommandResult,
    onSuccess: @escaping @MainActor () async -> Void = {}
  ) async throws -> CommandResult {
    let operation = BackgroundOperation(title: title, action: action, isCancellable: false)
    operations.append(operation)

    do {
      let result = try await execute()
      operation.capture(result)

      if result.succeeded {
        operation.finish(state: .succeeded)
        await onSuccess()
      } else {
        operation.finish(state: .failed(reason: operation.failureReason(defaultExitCode: result.exitCode)))
      }

      return result
    } catch {
      operation.capture(error)
      if error is CancellationError {
        operation.finish(state: .cancelled)
      } else {
        operation.finish(state: .failed(reason: operation.failureReason()))
      }
      throw error
    }
  }

  func cancel(_ operation: BackgroundOperation) {
    guard operation.isCancellable else { return }
    tasks[operation.id]?.cancel()
    operation.finish(state: .cancelled)
  }

  func dismiss(_ operation: BackgroundOperation) {
    guard operation.state.isFinished else { return }
    operations.removeAll { $0.id == operation.id }
  }

  func clearFinished() {
    operations.removeAll { $0.state.isFinished }
  }
}
