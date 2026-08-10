import Foundation
import TartKit

/// VM 会话所需的最小运行时接口。
///
/// TartClient 继续负责完整的 CLI API；这个窄接口只暴露虚拟机长驻进程
/// 和生命周期命令，避免会话管理器依赖所有 Tart 命令。
protocol VMRuntimeService: Sendable {
  var runtime: TartRuntime { get }

  func start(plan: VMRuntimeLaunchPlan) -> AsyncThrowingStream<CommandEvent, any Error>
  func stop(vmName: String, timeout: UInt?) async throws
  func suspend(vmName: String) async throws
}

/// Tart CLI 的运行时适配器。
///
/// Tart 作为独立进程存在，TartUI 不复制或修改 Tart 的虚拟化实现；上游更新
/// 时只需要替换这个适配器使用的 runtime bundle。
struct TartVMRuntimeService: VMRuntimeService {
  let runtime: TartRuntime
  private let client: TartClient

  init(runtime: TartRuntime, client: TartClient) {
    self.runtime = runtime
    self.client = client
  }

  func start(plan: VMRuntimeLaunchPlan) -> AsyncThrowingStream<CommandEvent, any Error> {
    client.stream(plan.arguments)
  }

  func stop(vmName: String, timeout: UInt? = nil) async throws {
    try await client.stop(name: vmName, timeout: timeout)
  }

  func suspend(vmName: String) async throws {
    try await client.suspend(name: vmName)
  }
}
