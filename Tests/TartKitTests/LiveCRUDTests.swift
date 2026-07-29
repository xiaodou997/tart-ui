import Foundation
import Testing
@testable import TartKit

/// 真实走一遍「创建 → 修改 → 重命名 → 删除」的端到端测试。
///
/// **默认不运行。** 需要显式启用：
///
/// ```
/// TARTPRO_LIVE_CRUD=1 swift test --filter LiveCRUDTests
/// ```
///
/// 创建的是空白 Linux 虚拟机，磁盘是稀疏文件，实际占用极小，而且从不启动它。
/// 名字带随机后缀并以 `tartpro-test-` 开头，避免撞上真实的虚拟机；
/// 无论测试成败都会在结束时清理。
@Suite("真实创建与删除", .enabled(if: ProcessInfo.processInfo.environment["TARTPRO_LIVE_CRUD"] == "1"), .serialized)
struct LiveCRUDTests {
  @Test("创建空白 Linux 虚拟机，改配置、重命名，最后删除")
  func fullLifecycle() async throws {
    let client = try TartClient()
    let suffix = UUID().uuidString.prefix(8).lowercased()
    let originalName = "tartpro-test-\(suffix)"
    let renamedName = "tartpro-test-renamed-\(suffix)"

    // 兜底清理：无论中途哪一步失败，都不留下测试残骸。
    defer {
      let cleanup = Task.detached {
        try? await client.delete(names: [originalName, renamedName])
      }
      _ = cleanup
    }

    // 创建。空白 Linux 虚拟机不需要下载任何东西，很快。
    var createFailed: String?
    var exitCode: Int32 = -1
    for try await event in client.create(name: originalName, source: .linux, diskSizeGB: 20) {
      switch event {
      case let .exited(code): exitCode = code
      case let .stderr(line):
        if line.lowercased().contains("error") { createFailed = line }
      case .stdout: break
      }
    }
    try #require(createFailed == nil, "创建失败：\(createFailed ?? "")")
    #expect(exitCode == 0)

    // 确认出现在列表里。
    let afterCreate = try await client.list(source: .local)
    let created = try #require(
      afterCreate.first { $0.name == originalName },
      "创建后没有在列表里找到 \(originalName)"
    )
    #expect(created.state == .stopped)

    // 读配置。
    let details = try await client.get(name: originalName)
    #expect(details.diskSizeGB == 20)
    let originalCPU = details.cpuCount

    // 改配置。
    let newCPU = originalCPU == 2 ? 4 : 2
    try await client.set(name: originalName, cpuCount: newCPU, memoryMB: 2048)

    let afterSet = try await client.get(name: originalName)
    #expect(afterSet.cpuCount == newCPU)
    #expect(afterSet.memoryMB == 2048)

    // 磁盘缩小必须被 tart 拒绝——这是我们在界面上拦截的依据。
    await #expect(throws: TartError.self) {
      try await client.set(name: originalName, diskSizeGB: 10)
    }

    // 重命名。
    try await client.rename(name: originalName, to: renamedName)

    let afterRename = try await client.list(source: .local)
    #expect(afterRename.contains { $0.name == renamedName })
    #expect(!afterRename.contains { $0.name == originalName })

    // 删除。
    try await client.delete(names: [renamedName])

    let afterDelete = try await client.list(source: .local)
    #expect(!afterDelete.contains { $0.name == renamedName })
    #expect(!afterDelete.contains { $0.name == originalName })
  }
}
