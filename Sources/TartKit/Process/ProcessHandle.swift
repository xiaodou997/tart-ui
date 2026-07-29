import Foundation

/// 对单次 `Process` 执行的封装。
///
/// 之所以不直接在 `TartExecutor` 里裸用 `Process`，是因为有两件事必须做对：
///
/// 1. **必须并发读取 stdout 和 stderr。** 先 `waitUntilExit()` 再读管道，会在输出超过
///    管道缓冲区（约 64KB）时死锁——子进程写满后阻塞，父进程又在等它退出。
///    `tart pull` 的输出远超这个量。
/// 2. **退出和读完不是一回事。** 进程退出后管道里可能还有未读数据，所以要等
///    「两路 EOF + 进程退出」三个条件都满足才算真正结束。
///
/// `@unchecked Sendable`：内部所有可变状态都由 `lock` 保护，`Process` 实例本身
/// 只在构造和 `terminate()` 中触碰。
final class ProcessHandle: @unchecked Sendable {
  private let process = Process()
  private let stdoutPipe = Pipe()
  private let stderrPipe = Pipe()

  private let lock = NSLock()
  private var stdoutEOF = false
  private var stderrEOF = false
  private var hasExited = false
  private var exitCode: Int32 = 0
  private var didFinish = false

  init(binaryURL: URL, arguments: [String], environment: [String: String]) {
    process.executableURL = binaryURL
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    // 不给子进程接终端输入：GUI 场景下没有 stdin 可用，
    // 若 tart 意外发起交互式提问，应当直接失败而不是永久挂起。
    process.standardInput = FileHandle.nullDevice
  }

  // MARK: - 累积模式

  /// 启动并等待结束，返回完整输出。
  func waitForCompletion(arguments: [String]) async throws -> CommandResult {
    let collector = OutputCollector()

    return try await withCheckedThrowingContinuation { continuation in
      let finish: @Sendable () -> Void = { [weak self] in
        guard let self, self.claimFinish() else { return }
        let (out, err) = collector.snapshot()
        continuation.resume(returning: CommandResult(
          arguments: arguments,
          stdout: out,
          stderr: err,
          exitCode: self.readExitCode()
        ))
      }

      installHandlers(
        onStdoutData: { collector.appendStdout($0) },
        onStderrData: { collector.appendStderr($0) },
        onAllDone: finish
      )

      do {
        try process.run()
      } catch {
        if claimFinish() {
          continuation.resume(throwing: TartError.launchFailed(underlying: error))
        }
      }
    }
  }

  // MARK: - 流式模式

  /// 启动并按行回调输出。回调发生在后台队列。
  func streamLines(
    onStdout: @escaping @Sendable (String) -> Void,
    onStderr: @escaping @Sendable (String) -> Void,
    onExit: @escaping @Sendable (Int32) -> Void
  ) throws {
    let stdoutSplitter = LineSplitter()
    let stderrSplitter = LineSplitter()

    installHandlers(
      onStdoutData: { data in
        for line in stdoutSplitter.push(data) { onStdout(line) }
      },
      onStderrData: { data in
        for line in stderrSplitter.push(data) { onStderr(line) }
      },
      onAllDone: { [weak self] in
        guard let self, self.claimFinish() else { return }
        // 收尾：管道关闭时可能还剩一段没有换行符结尾的内容。
        if let tail = stdoutSplitter.flush() { onStdout(tail) }
        if let tail = stderrSplitter.flush() { onStderr(tail) }
        onExit(self.readExitCode())
      }
    )

    do {
      try process.run()
    } catch {
      throw TartError.launchFailed(underlying: error)
    }
  }

  // MARK: - 终止

  /// 请求子进程退出。用于调用方取消时不留下孤儿进程。
  func terminate() {
    guard process.isRunning else { return }
    process.terminate()
  }

  /// 强制杀死。`terminate()`（SIGTERM）超时后的最后手段。
  func forceKill() {
    guard process.isRunning else { return }
    kill(process.processIdentifier, SIGKILL)
  }

  var processIdentifier: Int32 {
    process.isRunning ? process.processIdentifier : -1
  }

  // MARK: - 内部

  /// 安装三路回调，并在「两路 EOF + 进程退出」全部满足时触发 `onAllDone`。
  private func installHandlers(
    onStdoutData: @escaping @Sendable (Data) -> Void,
    onStderrData: @escaping @Sendable (Data) -> Void,
    onAllDone: @escaping @Sendable () -> Void
  ) {
    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        self?.markStdoutEOF()
        self?.notifyIfComplete(onAllDone)
      } else {
        onStdoutData(data)
      }
    }

    stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        self?.markStderrEOF()
        self?.notifyIfComplete(onAllDone)
      } else {
        onStderrData(data)
      }
    }

    process.terminationHandler = { [weak self] proc in
      self?.markExited(proc.terminationStatus)
      self?.notifyIfComplete(onAllDone)
    }
  }

  private func markStdoutEOF() {
    lock.lock(); defer { lock.unlock() }
    stdoutEOF = true
  }

  private func markStderrEOF() {
    lock.lock(); defer { lock.unlock() }
    stderrEOF = true
  }

  private func markExited(_ code: Int32) {
    lock.lock(); defer { lock.unlock() }
    hasExited = true
    exitCode = code
  }

  private func readExitCode() -> Int32 {
    lock.lock(); defer { lock.unlock() }
    return exitCode
  }

  /// 三个条件齐了才算结束。
  private func notifyIfComplete(_ onAllDone: @escaping @Sendable () -> Void) {
    lock.lock()
    let complete = stdoutEOF && stderrEOF && hasExited
    lock.unlock()

    if complete { onAllDone() }
  }

  /// 保证收尾逻辑只执行一次——三路回调可能并发抵达同一个「已完成」判定。
  private func claimFinish() -> Bool {
    lock.lock(); defer { lock.unlock() }
    if didFinish { return false }
    didFinish = true
    return true
  }
}

// MARK: - 辅助类型

/// 线程安全的输出累积器。
private final class OutputCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var stdout = Data()
  private var stderr = Data()

  func appendStdout(_ data: Data) {
    lock.lock(); defer { lock.unlock() }
    stdout.append(data)
  }

  func appendStderr(_ data: Data) {
    lock.lock(); defer { lock.unlock() }
    stderr.append(data)
  }

  func snapshot() -> (String, String) {
    lock.lock(); defer { lock.unlock() }
    return (
      String(decoding: stdout, as: UTF8.self),
      String(decoding: stderr, as: UTF8.self)
    )
  }
}

/// 把任意切分的字节流重新组装成完整行。
///
/// `readabilityHandler` 给到的 Data 边界是任意的，一行可能横跨两次回调，
/// 直接按块解码会把进度输出切碎。
private final class LineSplitter: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()

  func push(_ data: Data) -> [String] {
    lock.lock(); defer { lock.unlock() }
    buffer.append(data)

    var lines: [String] = []
    // tart 的进度输出用 \r 回到行首刷新，这里把 \r 也当作行边界，
    // 否则进度条会积成一整行迟迟不产出。
    while let index = buffer.firstIndex(where: { $0 == UInt8(ascii: "\n") || $0 == UInt8(ascii: "\r") }) {
      let lineData = buffer[buffer.startIndex..<index]
      if !lineData.isEmpty {
        lines.append(String(decoding: lineData, as: UTF8.self))
      }
      buffer = buffer[buffer.index(after: index)...]
    }
    return lines
  }

  /// 取出末尾没有行结束符的残留内容。
  func flush() -> String? {
    lock.lock(); defer { lock.unlock() }
    guard !buffer.isEmpty else { return nil }
    let tail = String(decoding: buffer, as: UTF8.self)
    buffer = Data()
    return tail.isEmpty ? nil : tail
  }
}
