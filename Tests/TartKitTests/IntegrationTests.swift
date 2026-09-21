import Foundation
import Testing
@testable import TartKit

/// 针对真实 tart 二进制的集成测试。
///
/// mock 测试只能证明「解码器和我写的样例一致」，证明不了「样例和真实输出一致」。
/// 这组测试补上后一半——上游改了输出格式，这里会立刻炸。
///
/// 仅包含只读命令（list / get / --version），不会创建、修改或删除任何虚拟机。
/// 没装 tart 的机器上整组跳过。
@Suite("集成测试（需要真实 tart）", .enabled(if: LiveTartRuntime.isInstalled))
struct IntegrationTests {
  private func makeClient() throws -> TartClient {
    try LiveTartRuntime.makeClient()
  }

  @Test("能定位到 tart 并读出版本号")
  func readsVersion() async throws {
    let version = try await makeClient().version()

    #expect(!version.isEmpty)
    // tart 的 --version 输出形如 "2.34.0"。
    #expect(version.first?.isNumber == true)
  }

  @Test("真实 list 输出能完整解码")
  func decodesRealListOutput() async throws {
    let entries = try await makeClient().list()

    // 条目数可能为 0（干净的机器），重点是解码不抛错。
    for entry in entries {
      #expect(!entry.name.isEmpty)
      #expect(entry.source != .unknown, "出现了未知来源，说明 tart 新增了 Source 取值")
      #expect(entry.state != .unknown, "出现了未知状态，说明 tart 新增了 State 取值")
      #expect(entry.diskSizeGB >= 0)
    }
  }

  @Test("按来源过滤的结果是全量的子集")
  func sourceFilterIsConsistent() async throws {
    let client = try makeClient()

    let all = try await client.list()
    let local = try await client.list(source: .local)

    #expect(local.allSatisfy { $0.source == .local })
    #expect(local.count <= all.count)
  }

  @Test("真实 get 输出能完整解码")
  func decodesRealGetOutput() async throws {
    let client = try makeClient()

    guard let first = try await client.list(source: .local).first else {
      // 本地没有 VM，这条没得测。
      return
    }

    let details = try await client.get(name: first.name)

    #expect(details.cpuCount > 0)
    #expect(details.memoryMB > 0)
    #expect(details.display.width > 0)
    #expect(details.state != .unknown)
    // list 和 get 对同一台 VM 的状态判断必须一致。
    #expect(details.state == first.state)
  }

  @Test("查询不存在的虚拟机会带回 tart 的原始错误信息")
  func reportsMissingVM() async throws {
    let client = try makeClient()
    let ghostName = "tartui-nonexistent-\(UUID().uuidString.prefix(8))"

    do {
      _ = try await client.get(name: ghostName)
      Issue.record("本应抛出错误")
    } catch let error as TartError {
      guard case let .commandFailed(_, exitCode, stderr) = error else {
        Issue.record("期望 commandFailed，实际是 \(error)")
        return
      }
      #expect(exitCode != 0)
      #expect(!stderr.isEmpty, "stderr 必须原样带回，否则用户看不到失败原因")
    }
  }
}

