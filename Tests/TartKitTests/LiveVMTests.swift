import Foundation
import Testing
@testable import TartKit

/// 真正启动一台虚拟机的端到端测试。
///
/// **默认不运行。** 这组测试会真的开机、跑几分钟、再关机，属于有副作用的操作，
/// 不该混在常规测试里。需要显式指定环境变量才会执行：
///
/// ```
/// TARTUI_LIVE_VM=sequoia swift test --filter LiveVMTests
/// ```
///
/// 故意不设默认虚拟机名——否则一次手滑就可能动到别人的虚拟机。
///
/// 用无图形模式（`--no-graphics`）启动，不占屏幕。关机走 `tart stop` 并给足超时，
/// 避免客户机还没准备好就被强制断电。
@Suite("真实虚拟机启停", .enabled(if: LiveVMConfig.isEnabled), .serialized)
struct LiveVMTests {
  /// 留给客户机完成启动的时间。macOS 冷启动通常 30–60 秒。
  static let bootWaitSeconds = 75
  /// 关机超时。给得比 tart 默认的 30 秒宽松，减少强制断电的机会。
  static let shutdownTimeout: UInt = 120

  @Test("无图形模式下启动、观察输出、再优雅关机")
  func startObserveAndStop() async throws {
    let vmName = try #require(LiveVMConfig.vmName)
    let client = try LiveTartRuntime.makeClient()

    // 前置检查：必须从已停止状态开始，避免动到正在使用的虚拟机。
    let before = try await client.list(source: .local)
    let target = try #require(before.first { $0.name == vmName }, "找不到虚拟机 \(vmName)")
    try #require(target.state == .stopped, "虚拟机 \(vmName) 当前状态是 \(target.state)，测试要求它处于已停止状态")

    let profile = RunProfile(name: "自动化测试", noGraphics: true)
    #expect(profile.arguments(vmName: vmName) == ["run", vmName, "--no-graphics"])

    // 收集输出的容器。流在后台 Task 里消费，测试主体负责轮询状态。
    let collector = LineCollector()

    let streamTask = Task {
      do {
        for try await event in client.runVM(name: vmName, profile: profile) {
          switch event {
          case .started: break
          case let .stdout(line): await collector.append(line, isError: false)
          case let .stderr(line): await collector.append(line, isError: true)
          case let .exited(code): await collector.markExited(code)
          }
        }
      } catch {
        await collector.markFailed(error.localizedDescription)
      }
    }

    // 确保无论测试怎么结束，都不会把虚拟机留在运行状态。
    defer { streamTask.cancel() }

    // 等待状态变为运行中。
    var becameRunning = false
    for _ in 0..<30 {
      try await Task.sleep(for: .seconds(2))
      let entries = try await client.list(source: .local)
      if entries.first(where: { $0.name == vmName })?.state == .running {
        becameRunning = true
        break
      }
      if await collector.hasFailed {
        break
      }
    }

    if let failure = await collector.failureReason {
      Issue.record("启动失败：\(failure)")
      return
    }
    #expect(becameRunning, "虚拟机在预期时间内没有进入运行状态")

    // 给客户机时间完成启动，否则关机信号可能无人响应，最终被强制断电。
    try await Task.sleep(for: .seconds(Self.bootWaitSeconds))

    // 优雅关机。
    try await client.stop(name: vmName, timeout: Self.shutdownTimeout)

    // 确认真的停了。
    var stopped = false
    for _ in 0..<30 {
      try await Task.sleep(for: .seconds(2))
      let entries = try await client.list(source: .local)
      if entries.first(where: { $0.name == vmName })?.state == .stopped {
        stopped = true
        break
      }
    }
    #expect(stopped, "虚拟机在关机后没有回到已停止状态")

    // tart 会把进度和状态信息写在 stderr 上，这里应当收到过内容。
    let lineCount = await collector.count
    #expect(lineCount > 0, "整个启动过程没有采集到任何输出，说明流式管道没有工作")
  }
}

enum LiveVMConfig {
  static var vmName: String? {
    guard let name = ProcessInfo.processInfo.environment["TARTUI_LIVE_VM"],
          !name.isEmpty else { return nil }
    return name
  }

  static var isEnabled: Bool { vmName != nil }
}

/// 线程安全的输出收集器。
actor LineCollector {
  private(set) var lines: [(text: String, isError: Bool)] = []
  private(set) var exitCode: Int32?
  private(set) var failureReason: String?

  var count: Int { lines.count }
  var hasFailed: Bool { failureReason != nil }

  func append(_ text: String, isError: Bool) {
    lines.append((text, isError))
  }

  func markExited(_ code: Int32) {
    exitCode = code
  }

  func markFailed(_ reason: String) {
    failureReason = reason
  }
}
