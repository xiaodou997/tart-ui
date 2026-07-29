import Foundation
import Testing
@testable import TartKit

@Suite("镜像拉取与推送")
struct PullPushTests {
  @Test("拉取默认不带多余参数")
  func pullMinimal() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    for try await _ in client.pull(remoteName: "ghcr.io/org/image:latest") {}

    #expect(mock.receivedArguments[0] == ["pull", "ghcr.io/org/image:latest"])
  }

  @Test("拉取的完整选项")
  func pullWithOptions() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    for try await _ in client.pull(remoteName: "img", insecure: true, concurrency: 8) {}

    #expect(mock.receivedArguments[0] == ["pull", "img", "--insecure", "--concurrency", "8"])
  }

  @Test("推送到多个远程引用")
  func pushMultipleTargets() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    for try await _ in client.push(
      localName: "local-vm",
      remoteNames: ["ghcr.io/org/img:v1", "ghcr.io/org/img:latest"]
    ) {}

    #expect(mock.receivedArguments[0] == [
      "push", "local-vm", "ghcr.io/org/img:v1", "ghcr.io/org/img:latest",
    ])
  }

  @Test("推送时附加标签")
  func pushWithLabels() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    for try await _ in client.push(
      localName: "vm",
      remoteNames: ["img"],
      chunkSizeMB: 4,
      labels: [
        ImageLabel(key: "org.opencontainers.image.version", value: "1.0"),
        ImageLabel(key: "build", value: "42"),
      ],
      populateCache: true
    ) {}

    let arguments = mock.receivedArguments[0]
    #expect(arguments.contains("--chunk-size"))
    #expect(arguments.contains("4"))
    #expect(arguments.contains("org.opencontainers.image.version=1.0"))
    #expect(arguments.contains("build=42"))
    #expect(arguments.contains("--populate-cache"))
  }

  @Test("键为空的标签会被跳过")
  func skipsEmptyLabels() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    for try await _ in client.push(
      localName: "vm",
      remoteNames: ["img"],
      labels: [ImageLabel(key: "", value: "orphan")]
    ) {}

    // 界面上新增一行还没填键名时会出现空串，不能传 `=orphan` 给 tart。
    #expect(!mock.receivedArguments[0].contains("=orphan"))
  }
}

@Suite("仓库登录")
struct LoginTests {
  @Test("密码通过标准输入传递，绝不出现在命令行参数里")
  func passwordGoesThroughStdin() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)
    let secret = "super-secret-password"

    try await client.login(host: "ghcr.io", username: "alice", password: secret)

    let arguments = mock.receivedArguments[0]

    // 这是本组测试最重要的一条：命令行参数会出现在 ps 输出里，
    // 同机的任何进程都能读到。密码只能走 stdin。
    #expect(!arguments.contains(secret))
    #expect(!arguments.joined(separator: " ").contains(secret))
    #expect(arguments.contains("--password-stdin"))

    let stdin = try #require(mock.receivedStdin[0])
    #expect(String(decoding: stdin, as: UTF8.self) == secret)
  }

  @Test("登录参数的基本形态")
  func loginArguments() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    try await client.login(host: "ghcr.io", username: "alice", password: "pw")

    #expect(mock.receivedArguments[0] == [
      "login", "ghcr.io", "--username", "alice", "--password-stdin",
    ])
  }

  @Test("可选的 insecure 与跳过校验")
  func loginOptions() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    try await client.login(
      host: "registry.local", username: "u", password: "p",
      insecure: true, validate: false
    )

    let arguments = mock.receivedArguments[0]
    #expect(arguments.contains("--insecure"))
    #expect(arguments.contains("--no-validate"))
  }

  @Test("登录失败时错误信息里的用户名被遮蔽")
  func failureMasksUsername() async throws {
    let mock = MockExecutor()
    mock.enqueue(stderr: "Error: unauthorized", exitCode: 1)
    let client = TartClient(executor: mock)

    do {
      try await client.login(host: "ghcr.io", username: "alice", password: "pw")
      Issue.record("本应抛出错误")
    } catch let error as TartError {
      guard case let .commandFailed(command, _, stderr) = error else {
        Issue.record("期望 commandFailed，实际是 \(error)")
        return
      }
      // 错误信息可能被记进日志，用户名不该跟着流出去。
      #expect(!command.contains("alice"))
      #expect(command.contains("***"))
      #expect(stderr.contains("unauthorized"))
    }
  }

  @Test("注销")
  func logout() async throws {
    let mock = MockExecutor()
    let client = TartClient(executor: mock)

    try await client.logout(host: "ghcr.io")

    #expect(mock.receivedArguments[0] == ["logout", "ghcr.io"])
  }
}

@Suite("标准输入传递")
struct StdinTests {
  @Test("真实进程能收到标准输入的内容")
  func realProcessReceivesStdin() async throws {
    // 用 /bin/cat 验证 stdin 管道确实通了，而不只是参数拼对了。
    let executor = TartExecutor(binaryURL: URL(fileURLWithPath: "/bin/cat"))

    let result = try await executor.run([], stdin: Data("hello from stdin".utf8))

    #expect(result.stdout == "hello from stdin")
    #expect(result.exitCode == 0)
  }

  @Test("不传 stdin 时子进程立即读到 EOF 而不是挂起")
  func noStdinMeansImmediateEOF() async throws {
    // 若把 stdin 接到终端，cat 会永久等待输入，整个应用就卡死了。
    let executor = TartExecutor(binaryURL: URL(fileURLWithPath: "/bin/cat"))

    let result = try await executor.run([])

    #expect(result.stdout.isEmpty)
    #expect(result.exitCode == 0)
  }
}
