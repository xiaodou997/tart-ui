import Foundation
import Testing
@testable import TartKit
@testable import TartUI

@Suite("VM runtime 会话")
@MainActor
struct VMRuntimeSessionTests {
  @Test("原生窗口会话记录完整的启动阶段")
  func nativeWindowLifecycle() {
    let plan = VMRuntimeLaunchPlan(
      vmName: "sequoia",
      profileName: "Default",
      displayMode: .nativeWindow,
      arguments: ["run", "sequoia"]
    )
    let session = VMRuntimeSession(launchPlan: plan, logFileURL: nil)

    #expect(session.state == .starting)
    #expect(session.recentLines.first?.text == "$ tart run sequoia")

    session.markProcessStarted(processIdentifier: 42)
    #expect(session.state == .waitingForWindow)
    #expect(session.processIdentifier == 42)

    session.markWindowWaitTimedOut()
    #expect(session.state == .running)
    #expect(session.windowWarning != nil)

    session.markWindowReady()
    #expect(session.state == .running)
    #expect(session.isWindowReady)
    #expect(session.windowWarning == nil)

    session.markExited(code: 0)
    #expect(session.state == .exited(code: 0))
    #expect(session.recentLines.last?.text.contains("0") == true)
  }

  @Test("迟到的窗口事件不会覆盖停止状态")
  func lateWindowReadyPreservesStoppingState() {
    let plan = VMRuntimeLaunchPlan(
      vmName: "sequoia",
      profileName: "Default",
      displayMode: .nativeWindow,
      arguments: ["run", "sequoia"]
    )
    let session = VMRuntimeSession(launchPlan: plan, logFileURL: nil)

    session.markProcessStarted(processIdentifier: 42)
    session.markStopping()
    session.markWindowReady()

    #expect(session.state == .stopping)
    #expect(session.isWindowReady)
  }

  @Test("Agent 窗口事件不会作为错误日志显示")
  func coordinatorConsumesWindowReadyMarker() async throws {
    let runtime = EventRuntime(events: [
      .started(processIdentifier: 42),
      .stderr("TARTUI_EVENT:window-ready"),
      .exited(0),
    ])
    let coordinator = VMRuntimeCoordinator(runtime: runtime)
    let session = coordinator.start(vmName: "sequoia", profile: RunProfile())

    for _ in 0..<20 where session.state.isActive {
      await Task.yield()
    }

    #expect(session.state == .exited(code: 0))
    #expect(session.isWindowReady)
    #expect(!session.recentLines.contains { $0.text.contains("TARTUI_EVENT") })
  }
}

private struct EventRuntime: VMRuntimeService {
  let runtime = TartRuntime(
    binaryURL: URL(fileURLWithPath: "/usr/bin/true"),
    source: .userOverride
  )
  let events: [CommandEvent]

  func start(plan _: VMRuntimeLaunchPlan) -> AsyncThrowingStream<CommandEvent, any Error> {
    AsyncThrowingStream { continuation in
      for event in events {
        continuation.yield(event)
      }
      continuation.finish()
    }
  }

  func stop(vmName _: String, timeout _: UInt?) async throws {}
  func suspend(vmName _: String) async throws {}
}
