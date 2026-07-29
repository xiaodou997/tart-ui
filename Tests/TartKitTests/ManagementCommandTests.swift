import Foundation
import Testing
@testable import TartKit

@Suite("创建与克隆")
struct CreationCommandTests {
  @Test("从 IPSW 创建 macOS 虚拟机")
  func createFromIPSW() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    for try await _ in client.create(name: "new-vm", source: .macOSFromIPSW("/tmp/restore.ipsw")) {}

    #expect(mock.receivedArguments[0] == ["create", "new-vm", "--from-ipsw", "/tmp/restore.ipsw"])
  }

  @Test("latest 作为 IPSW 路径原样传递")
  func createFromLatest() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    for try await _ in client.create(name: "vm", source: .latestMacOS) {}

    // tart 认识字面量 latest，不需要我们去解析成具体 URL。
    #expect(mock.receivedArguments[0] == ["create", "vm", "--from-ipsw", "latest"])
  }

  @Test("创建 Linux 虚拟机并指定磁盘")
  func createLinux() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    for try await _ in client.create(
      name: "ubuntu", source: .linux, diskSizeGB: 80, diskFormat: .asif
    ) {}

    #expect(mock.receivedArguments[0] == [
      "create", "ubuntu", "--linux", "--disk-size", "80", "--disk-format", "asif",
    ])
  }

  @Test("克隆时只传显式指定的选项")
  func cloneOmitsDefaults() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    for try await _ in client.clone(source: "ghcr.io/org/image:latest", newName: "local-copy") {}

    #expect(mock.receivedArguments[0] == ["clone", "ghcr.io/org/image:latest", "local-copy"])
  }

  @Test("克隆的完整选项")
  func cloneWithOptions() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    for try await _ in client.clone(
      source: "base", newName: "copy", insecure: true, concurrency: 8, pruneLimitGB: 200
    ) {}

    #expect(mock.receivedArguments[0] == [
      "clone", "base", "copy", "--insecure", "--concurrency", "8", "--prune-limit", "200",
    ])
  }
}

@Suite("配置修改")
struct SetCommandTests {
  @Test("只传改动过的项")
  func onlyChangedFields() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    try await client.set(name: "vm", cpuCount: 8)

    #expect(mock.receivedArguments[0] == ["set", "vm", "--cpu", "8"])
  }

  @Test("一项都没改就不执行命令")
  func noChangesSkipsExecution() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    try await client.set(name: "vm")

    // 白跑一趟没有意义。
    #expect(mock.receivedArguments.isEmpty)
  }

  @Test("完整的配置修改")
  func allFields() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    try await client.set(
      name: "vm",
      cpuCount: 4,
      memoryMB: 8192,
      display: DisplayResolution(width: 1920, height: 1080),
      randomMAC: true,
      diskSizeGB: 100
    )

    let arguments = mock.receivedArguments[0]
    #expect(arguments.contains("--cpu"))
    #expect(arguments.contains("8192"))
    #expect(arguments.contains("1920x1080"))
    #expect(arguments.contains("--random-mac"))
    #expect(arguments.contains("--disk-size"))
  }

  @Test("分辨率单位作为后缀附加")
  func displayUnitSuffix() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    try await client.set(
      name: "vm",
      display: DisplayResolution(width: 1200, height: 800),
      displayUnit: .px
    )

    #expect(mock.receivedArguments[0].contains("1200x800px"))
  }

  @Test("display-refit 的开与关是两个不同的参数")
  func displayRefitBothWays() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    try await client.set(name: "vm", displayRefit: true)
    try await client.set(name: "vm", displayRefit: false)

    #expect(mock.receivedArguments[0].contains("--display-refit"))
    #expect(mock.receivedArguments[1].contains("--no-display-refit"))
  }
}

@Suite("重命名与删除")
struct RenameDeleteTests {
  @Test("重命名")
  func rename() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    try await client.rename(name: "old", to: "new")

    #expect(mock.receivedArguments[0] == ["rename", "old", "new"])
  }

  @Test("一次删除多台")
  func deleteMultiple() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    try await client.delete(names: ["a", "b", "c"])

    #expect(mock.receivedArguments[0] == ["delete", "a", "b", "c"])
  }

  @Test("空列表不执行删除")
  func deleteEmptyIsNoop() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    try await client.delete(names: [])

    // 空的 delete 命令会被 tart 当成语法错误，不如直接不跑。
    #expect(mock.receivedArguments.isEmpty)
  }
}

@Suite("磁盘调整校验")
struct DiskResizeTests {
  @Test("缩小磁盘被拒绝")
  func rejectsShrink() {
    // tart 只允许扩大磁盘。与其让用户填完再看报错，不如界面上直接拦住。
    #expect(!DiskResizeValidation.isValid(currentGB: 100, targetGB: 50))
    #expect(DiskResizeValidation.validate(currentGB: 100, targetGB: 50) != nil)
  }

  @Test("扩大和保持不变都可以")
  func allowsGrowAndSame() {
    #expect(DiskResizeValidation.isValid(currentGB: 50, targetGB: 100))
    #expect(DiskResizeValidation.isValid(currentGB: 50, targetGB: 50))
    #expect(DiskResizeValidation.validate(currentGB: 50, targetGB: 100) == nil)
  }

  @Test("拒绝信息里包含当前和目标大小")
  func messageIsInformative() throws {
    let message = try #require(DiskResizeValidation.validate(currentGB: 100, targetGB: 50))

    #expect(message.contains("100"))
    #expect(message.contains("50"))
  }
}
