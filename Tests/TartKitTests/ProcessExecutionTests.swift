import Foundation
import Testing
@testable import TartKit

/// 进程执行层的测试。
///
/// 用 `/bin/sh` 而不是 tart：这一层是通用的进程封装，与 tart 无关，
/// 用 shell 能精确构造大输出、非零退出、长时运行这些边界情况，
/// 而且完全没有副作用。
@Suite("进程执行")
struct ProcessExecutionTests {
  private func shell(_ script: String) -> (TartExecutor, [String]) {
    (TartExecutor(binaryURL: URL(fileURLWithPath: "/bin/sh")), ["-c", script])
  }

  @Test("取回 stdout 和退出码")
  func capturesStdout() async throws {
    let (executor, args) = shell("echo hello")

    let result = try await executor.run(args)

    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    #expect(result.exitCode == 0)
    #expect(result.succeeded)
  }

  @Test("stdout 与 stderr 分开收集")
  func separatesStreams() async throws {
    let (executor, args) = shell("echo out; echo err >&2")

    let result = try await executor.run(args)

    #expect(result.stdout.contains("out"))
    #expect(!result.stdout.contains("err"))
    #expect(result.stderr.contains("err"))
  }

  @Test("非零退出码如实带回")
  func reportsExitCode() async throws {
    let (executor, args) = shell("exit 42")

    let result = try await executor.run(args)

    #expect(result.exitCode == 42)
    #expect(!result.succeeded)
  }

  @Test("大量输出不会死锁")
  func largeOutputDoesNotDeadlock() async throws {
    // 这是 ProcessHandle 存在的首要理由：先 waitUntilExit 再读管道，
    // 会在输出超过管道缓冲区（约 64KB）时死锁。这里生成约 1MB。
    let (executor, args) = shell("for i in $(seq 1 20000); do echo 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; done")

    let result = try await executor.run(args)

    #expect(result.exitCode == 0)
    #expect(result.stdout.count > 1_000_000)
  }

  @Test("stdout 和 stderr 同时大量输出也不会死锁")
  func largeOutputOnBothStreamsDoesNotDeadlock() async throws {
    // 只读一路同样会卡死另一路。
    let (executor, args) = shell("""
      for i in $(seq 1 5000); do
        echo 'stdout-line-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        echo 'stderr-line-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' >&2
      done
      """)

    let result = try await executor.run(args)

    #expect(result.exitCode == 0)
    #expect(result.stdout.count > 200_000)
    #expect(result.stderr.count > 200_000)
  }

  @Test("启动不存在的可执行文件会报 launchFailed")
  func launchFailureIsReported() async throws {
    let executor = TartExecutor(binaryURL: URL(fileURLWithPath: "/nonexistent/binary"))

    await #expect(throws: TartError.self) {
      _ = try await executor.run([])
    }
  }
}

@Suite("流式执行")
struct StreamingTests {
  private func shell(_ script: String) -> (TartExecutor, [String]) {
    (TartExecutor(binaryURL: URL(fileURLWithPath: "/bin/sh")), ["-c", script])
  }

  @Test("按行产出输出并以退出事件收尾")
  func streamsLinesThenExit() async throws {
    let (executor, args) = shell("echo one; echo two; echo three")

    var stdoutLines: [String] = []
    var exitCode: Int32?

    for try await event in executor.stream(args) {
      switch event {
      case let .stdout(line): stdoutLines.append(line)
      case .stderr: break
      case let .exited(code): exitCode = code
      }
    }

    #expect(stdoutLines == ["one", "two", "three"])
    #expect(exitCode == 0)
  }

  @Test("跨读取边界的行会被正确重组")
  func reassemblesSplitLines() async throws {
    // readabilityHandler 给到的数据边界是任意的，一行可能横跨两次回调。
    // 这里让每段之间有延迟，强制拆分。
    let (executor, args) = shell("printf 'part1'; sleep 0.2; printf 'part2\\n'")

    var lines: [String] = []
    for try await event in executor.stream(args) {
      if case let .stdout(line) = event { lines.append(line) }
    }

    // 必须重组成一行，而不是切成两条。
    #expect(lines == ["part1part2"])
  }

  @Test("回车刷新的进度输出会被当作独立行")
  func treatsCarriageReturnAsLineBreak() async throws {
    // tart 的下载进度用 \r 回到行首刷新，不按 \r 切分的话进度会积成一整行。
    let (executor, args) = shell("printf 'progress 1\\rprogress 2\\rprogress 3\\n'")

    var lines: [String] = []
    for try await event in executor.stream(args) {
      if case let .stdout(line) = event { lines.append(line) }
    }

    #expect(lines == ["progress 1", "progress 2", "progress 3"])
  }

  @Test("没有换行符结尾的末尾内容也会产出")
  func flushesTrailingContent() async throws {
    let (executor, args) = shell("printf 'no trailing newline'")

    var lines: [String] = []
    for try await event in executor.stream(args) {
      if case let .stdout(line) = event { lines.append(line) }
    }

    #expect(lines == ["no trailing newline"])
  }

  @Test("流式模式下 stderr 单独成路")
  func streamsStderrSeparately() async throws {
    let (executor, args) = shell("echo out; echo err >&2")

    var stdout: [String] = []
    var stderr: [String] = []
    for try await event in executor.stream(args) {
      switch event {
      case let .stdout(line): stdout.append(line)
      case let .stderr(line): stderr.append(line)
      case .exited: break
      }
    }

    #expect(stdout == ["out"])
    #expect(stderr == ["err"])
  }

  @Test("提前退出循环会终止子进程")
  func abandoningStreamTerminatesProcess() async throws {
    // 对应用户关掉日志窗口的场景：不能把 tart 留成孤儿进程。
    let marker = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("tartui-orphan-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: marker) }

    let (executor, args) = shell("""
      trap 'exit 0' TERM
      echo started
      sleep 30
      touch \(marker.path)
      """)

    for try await event in executor.stream(args) {
      if case .stdout = event {
        break  // 收到第一行就放弃这条流
      }
    }

    // 给子进程一点时间响应 SIGTERM。
    try await Task.sleep(for: .milliseconds(600))

    // 进程若还活着，30 秒后会创建这个文件；此刻它必须已经被终止。
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }

  @Test("取消 Task 会终止子进程")
  func cancellingTaskTerminatesProcess() async throws {
    let executor = TartExecutor(binaryURL: URL(fileURLWithPath: "/bin/sh"))

    let task = Task {
      try await executor.run(["-c", "sleep 30"])
    }

    try await Task.sleep(for: .milliseconds(300))
    task.cancel()

    // 若取消不生效，这里会等满 30 秒。
    let start = Date()
    _ = try? await task.value
    #expect(Date().timeIntervalSince(start) < 5)
  }
}
