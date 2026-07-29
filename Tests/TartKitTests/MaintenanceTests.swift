import Foundation
import Testing
@testable import TartKit

@Suite("导入导出")
struct ExportImportTests {
  @Test("导出到指定路径")
  func exportWithPath() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    for try await _ in client.export(name: "vm", to: "/tmp/vm.tvm") {}

    #expect(mock.receivedArguments[0] == ["export", "vm", "/tmp/vm.tvm"])
  }

  @Test("不给路径时由 tart 决定输出位置")
  func exportWithoutPath() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    for try await _ in client.export(name: "vm", to: nil) {}

    #expect(mock.receivedArguments[0] == ["export", "vm"])
  }

  @Test("导入")
  func importVM() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    for try await _ in client.importVM(from: "/tmp/vm.tvm", name: "restored") {}

    #expect(mock.receivedArguments[0] == ["import", "/tmp/vm.tvm", "restored"])
  }
}

@Suite("清理命令")
struct PruneCommandTests {
  @Test("没有任何条件时拒绝执行")
  func requiresCriteria() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    // tart 自己也会拒绝，但不如在这里就挡住，省一次进程往返。
    await #expect(throws: TartError.self) {
      try await client.prune(target: .caches)
    }
    #expect(mock.receivedArguments.isEmpty)
  }

  @Test("按天数清理缓存")
  func pruneOlderThan() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    try await client.prune(target: .caches, olderThanDays: 7)

    #expect(mock.receivedArguments[0] == ["prune", "--entries", "caches", "--older-than", "7"])
  }

  @Test("按空间预算清理虚拟机")
  func pruneSpaceBudget() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    try await client.prune(target: .vms, spaceBudgetGB: 100)

    #expect(mock.receivedArguments[0] == ["prune", "--entries", "vms", "--space-budget", "100"])
  }
}

@Suite("清理预览")
struct PrunePlannerTests {
  private func entry(_ name: String, sizeGB: Int, daysAgo: Double) -> VMListEntry {
    VMListEntry(
      source: .oci,
      name: name,
      diskSizeGB: sizeGB,
      allocatedSizeGB: sizeGB,
      accessedAt: Date().addingTimeInterval(-daysAgo * 86400),
      state: .stopped
    )
  }

  @Test("按天数筛出过期条目")
  func selectsOldEntries() {
    let entries = [
      entry("fresh", sizeGB: 10, daysAgo: 1),
      entry("stale", sizeGB: 20, daysAgo: 30),
      entry("ancient", sizeGB: 5, daysAgo: 90),
    ]

    let plan = PrunePlanner.plan(
      entries: entries, target: .caches, olderThanDays: 7, spaceBudgetGB: nil
    )

    #expect(plan.candidates.map(\.name).sorted() == ["ancient", "stale"])
    #expect(plan.reclaimedGB == 25)
  }

  @Test("空间预算按最近访问顺序保留")
  func spaceBudgetKeepsRecent() {
    let entries = [
      entry("newest", sizeGB: 30, daysAgo: 1),
      entry("middle", sizeGB: 30, daysAgo: 10),
      entry("oldest", sizeGB: 30, daysAgo: 20),
    ]

    // 预算 60 GB：最近的两个各 30 GB 刚好装下，最老的被删。
    let plan = PrunePlanner.plan(
      entries: entries, target: .caches, olderThanDays: nil, spaceBudgetGB: 60
    )

    #expect(plan.candidates.map(\.name) == ["oldest"])
  }

  @Test("放不下的大条目被删后，后面的小条目仍可能保留")
  func largeEntrySkippedButSmallerKept() {
    // 这是 tart 逻辑的一个细节：它逐个判断剩余预算，
    // 而不是「超出预算后把剩下的全删掉」。
    let entries = [
      entry("recent-small", sizeGB: 10, daysAgo: 1),
      entry("big", sizeGB: 100, daysAgo: 5),
      entry("older-small", sizeGB: 5, daysAgo: 10),
    ]

    let plan = PrunePlanner.plan(
      entries: entries, target: .caches, olderThanDays: nil, spaceBudgetGB: 20
    )

    // 预算 20：recent-small 占 10 剩 10；big 要 100 装不下被删；
    // older-small 只要 5，剩余 10 装得下，保留。
    #expect(plan.candidates.map(\.name) == ["big"])
  }

  @Test("两个条件同时生效时取并集")
  func combinesCriteria() {
    let entries = [
      entry("recent-big", sizeGB: 100, daysAgo: 1),
      entry("old-small", sizeGB: 5, daysAgo: 60),
    ]

    let plan = PrunePlanner.plan(
      entries: entries, target: .caches, olderThanDays: 30, spaceBudgetGB: 50
    )

    // old-small 因为过期被选中，recent-big 因为超预算被选中。
    #expect(plan.candidates.count == 2)
  }

  @Test("清理缓存时预览标记为可能不完整")
  func cachesPreviewIsMarkedIncomplete() {
    // IPSW 缓存不在 tart list 的输出里，预览必然看不到那部分。
    let plan = PrunePlanner.plan(
      entries: [], target: .caches, olderThanDays: 7, spaceBudgetGB: nil
    )

    #expect(plan.mayBeIncomplete)
  }

  @Test("清理本地虚拟机时预览是完整的")
  func vmsPreviewIsComplete() {
    let plan = PrunePlanner.plan(
      entries: [], target: .vms, olderThanDays: 7, spaceBudgetGB: nil
    )

    #expect(!plan.mayBeIncomplete)
  }

  @Test("没有符合条件的条目时计划为空")
  func emptyPlan() {
    let plan = PrunePlanner.plan(
      entries: [entry("fresh", sizeGB: 10, daysAgo: 1)],
      target: .vms, olderThanDays: 30, spaceBudgetGB: nil
    )

    #expect(plan.isEmpty)
    #expect(plan.reclaimedGB == 0)
  }
}

@Suite("虚拟机内执行命令")
struct ExecTests {
  @Test("非交互式执行不带 -i 和 -t")
  func nonInteractive() async throws {
    let mock = MockExecutor()
    mock.enqueue(stdout: "hello\n")
    let client = TartClient(executor: mock)

    let result = try await client.exec(name: "vm", command: ["echo", "hello"])

    // 交互式需要接管标准输入和 PTY，是另一套机制，这里不涉及。
    #expect(mock.receivedArguments[0] == ["exec", "vm", "echo", "hello"])
    #expect(!mock.receivedArguments[0].contains("-i"))
    #expect(!mock.receivedArguments[0].contains("-t"))
    #expect(result.stdout == "hello\n")
  }

  @Test("空命令被拒绝")
  func rejectsEmptyCommand() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    await #expect(throws: TartError.self) {
      _ = try await client.exec(name: "vm", command: [])
    }
  }

  @Test("客户机内的非零退出码不当作错误抛出")
  func guestExitCodeIsReturnedNotThrown() async throws {
    let mock = MockExecutor()
    mock.enqueue(stdout: "", stderr: "not found", exitCode: 127)
    let client = TartClient(executor: mock)

    // 退出码来自虚拟机里的命令，非零是正常结果而不是 tart 失败，
    // 交给调用方判断而不是在这里抛错。
    let result = try await client.exec(name: "vm", command: ["missing-cmd"])

    #expect(result.exitCode == 127)
    #expect(result.stderr.contains("not found"))
  }
}
