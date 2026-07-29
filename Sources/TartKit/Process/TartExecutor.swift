import Foundation

/// 一次命令执行的完整结果。
public struct CommandResult: Sendable {
  public let arguments: [String]
  public let stdout: String
  public let stderr: String
  public let exitCode: Int32

  public var succeeded: Bool { exitCode == 0 }

  public init(arguments: [String], stdout: String, stderr: String, exitCode: Int32) {
    self.arguments = arguments
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }
}

/// 流式执行时逐条产出的事件。
///
/// `pull` / `clone` 的进度只在 stderr 上滚动，`run` 更是长驻不退出，
/// 这类命令不能等它结束再取输出。
public enum CommandEvent: Sendable {
  case stdout(String)
  case stderr(String)
  case exited(Int32)
}

/// 执行 tart 命令的抽象。
///
/// 抽成协议是为了让上层逻辑能在没有真实 tart、也不真的开虚拟机的前提下被测试。
public protocol TartExecuting: Sendable {
  /// 执行并等待结束，取回完整输出。适用于 list / get / ip 这类瞬时命令。
  ///
  /// - Parameter stdin: 写入子进程标准输入的数据。密码必须走这里，
  ///   而不是命令行参数——后者会出现在 `ps` 输出里，被同机的其他进程看到。
  func run(_ arguments: [String], stdin: Data?) async throws -> CommandResult

  /// 执行并流式产出输出。适用于 pull / clone / run 这类长时命令。
  func stream(_ arguments: [String]) -> AsyncThrowingStream<CommandEvent, any Error>
}

extension TartExecuting {
  public func run(_ arguments: [String]) async throws -> CommandResult {
    try await run(arguments, stdin: nil)
  }
}

/// 基于 `Foundation.Process` 的真实实现。
public struct TartExecutor: TartExecuting {
  private let binaryURL: URL
  private let environment: [String: String]

  public init(binaryURL: URL, environment: [String: String]? = nil) {
    self.binaryURL = binaryURL
    // tart 自身要读 ~/.tart，必须保证 HOME 存在；其余继承宿主环境即可。
    self.environment = environment ?? ProcessInfo.processInfo.environment
  }

  public func run(_ arguments: [String], stdin: Data? = nil) async throws -> CommandResult {
    let handle = ProcessHandle(
      binaryURL: binaryURL,
      arguments: arguments,
      environment: environment,
      stdinData: stdin
    )

    return try await withTaskCancellationHandler {
      try await handle.waitForCompletion(arguments: arguments)
    } onCancel: {
      handle.terminate()
    }
  }

  public func stream(_ arguments: [String]) -> AsyncThrowingStream<CommandEvent, any Error> {
    AsyncThrowingStream { continuation in
      let handle = ProcessHandle(binaryURL: binaryURL, arguments: arguments, environment: environment)

      continuation.onTermination = { reason in
        // 调用方提前放弃了这条流（比如关掉了日志窗口），别把子进程留成孤儿。
        if case .cancelled = reason {
          handle.terminate()
        }
      }

      do {
        try handle.streamLines(
          onStdout: { continuation.yield(.stdout($0)) },
          onStderr: { continuation.yield(.stderr($0)) },
          onExit: { code in
            continuation.yield(.exited(code))
            continuation.finish()
          }
        )
      } catch {
        continuation.finish(throwing: error)
      }
    }
  }
}
