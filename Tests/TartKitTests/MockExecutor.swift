import Foundation
@testable import TartKit

/// 可编程的执行器替身。
///
/// 让 TartClient 的参数拼装和输出解码能在没有 tart、也不真开虚拟机的情况下被验证。
final class MockExecutor: TartExecuting, @unchecked Sendable {
  /// 按调用顺序排队的响应。
  private var responses: [Result<CommandResult, any Error>] = []
  private let lock = NSLock()

  /// 记录下每一次实际收到的参数，供断言检查。
  private(set) var receivedArguments: [[String]] = []

  var streamEvents: [CommandEvent] = []

  func enqueue(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
    lock.withLock {
      responses.append(.success(CommandResult(
        arguments: [], stdout: stdout, stderr: stderr, exitCode: exitCode
      )))
    }
  }

  func enqueue(error: any Error) {
    lock.withLock { responses.append(.failure(error)) }
  }

  func run(_ arguments: [String]) async throws -> CommandResult {
    let response: Result<CommandResult, any Error>? = lock.withLock {
      receivedArguments.append(arguments)
      return responses.isEmpty ? nil : responses.removeFirst()
    }

    guard let response else {
      return CommandResult(arguments: arguments, stdout: "", stderr: "", exitCode: 0)
    }

    switch response {
    case let .success(result):
      return CommandResult(
        arguments: arguments,
        stdout: result.stdout,
        stderr: result.stderr,
        exitCode: result.exitCode
      )
    case let .failure(error):
      throw error
    }
  }

  func stream(_ arguments: [String]) -> AsyncThrowingStream<CommandEvent, any Error> {
    let events = lock.withLock {
      receivedArguments.append(arguments)
      return streamEvents
    }

    return AsyncThrowingStream { continuation in
      for event in events {
        continuation.yield(event)
      }
      continuation.finish()
    }
  }
}
