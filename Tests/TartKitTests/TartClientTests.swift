import Foundation
import Testing
@testable import TartKit

// 下面的 JSON 全部取自 tart 2.34.0 的真实输出，不是手编的。
// 上游改 schema 时，这些用例应当第一时间失败。

private let listJSON = """
[
  {
    "Disk" : 50,
    "Running" : false,
    "Name" : "sequoia",
    "State" : "stopped",
    "Accessed" : "2026-07-29T02:03:18Z",
    "Size" : 31,
    "Source" : "local"
  },
  {
    "Source" : "OCI",
    "Running" : false,
    "Accessed" : "2026-07-29T00:26:15Z",
    "Size" : 33,
    "State" : "stopped",
    "Name" : "ghcr.io/cirruslabs/macos-sequoia-base:latest",
    "Disk" : 50
  }
]
"""

private let getJSON = """
{
  "CPU" : 4,
  "DiskFormat" : "raw",
  "OS" : "darwin",
  "State" : "stopped",
  "Display" : "1024x768",
  "Size" : "31.057",
  "Disk" : 50,
  "Memory" : 8192,
  "Running" : false
}
"""

@Suite("TartClient 命令拼装")
struct CommandConstructionTests {
  @Test("list 默认请求 JSON 格式且不限定来源")
  func listUsesJSONFormat() async throws {
    let mock = MockExecutor()
    mock.enqueue(stdout: listJSON)
    let client = TartClient(executor: mock)

    _ = try await client.list()

    #expect(mock.receivedArguments == [["list", "--format", "json"]])
  }

  @Test("list 按来源过滤时映射成 tart 认识的取值")
  func listMapsSourceFilter() async throws {
    let mock = MockExecutor()
    mock.enqueue(stdout: "[]")
    mock.enqueue(stdout: "[]")
    let client = TartClient(executor: mock)

    _ = try await client.list(source: .local)
    _ = try await client.list(source: .oci)

    // 注意 OCI 在 JSON 里是大写，但命令行参数要小写。
    #expect(mock.receivedArguments[0] == ["list", "--format", "json", "--source", "local"])
    #expect(mock.receivedArguments[1] == ["list", "--format", "json", "--source", "oci"])
  }

  @Test("ip 只在显式指定时才附加可选参数")
  func ipOmitsUnsetOptions() async throws {
    let mock = MockExecutor()
    mock.enqueue(stdout: "192.168.64.5\n")
    mock.enqueue(stdout: "192.168.64.5\n")
    let client = TartClient(executor: mock)

    _ = try await client.ip(name: "sequoia")
    _ = try await client.ip(name: "sequoia", waitSeconds: 30, resolver: .arp)

    #expect(mock.receivedArguments[0] == ["ip", "sequoia"])
    #expect(mock.receivedArguments[1] == ["ip", "sequoia", "--wait", "30", "--resolver", "arp"])
  }

  @Test("ip 结果会去掉尾部换行")
  func ipTrimsOutput() async throws {
    let mock = MockExecutor()
    mock.enqueue(stdout: "192.168.64.5\n")
    let client = TartClient(executor: mock)

    #expect(try await client.ip(name: "sequoia") == "192.168.64.5")
  }
}

@Suite("输出解码")
struct DecodingTests {
  @Test("list 输出解码成条目列表")
  func decodesList() async throws {
    let mock = MockExecutor()
    mock.enqueue(stdout: listJSON)
    let client = TartClient(executor: mock)

    let entries = try await client.list()

    #expect(entries.count == 2)

    let local = entries[0]
    #expect(local.name == "sequoia")
    #expect(local.source == .local)
    #expect(local.diskSizeGB == 50)
    #expect(local.allocatedSizeGB == 31)
    #expect(local.state == .stopped)
    #expect(local.isRunning == false)

    let oci = entries[1]
    #expect(oci.source == .oci)
    #expect(oci.name == "ghcr.io/cirruslabs/macos-sequoia-base:latest")
  }

  @Test("本地 VM 与同名 OCI 镜像不会撞 ID")
  func idDisambiguatesSources() {
    let local = VMListEntry(
      source: .local, name: "base", diskSizeGB: 50,
      allocatedSizeGB: 10, accessedAt: .now, state: .stopped
    )
    let oci = VMListEntry(
      source: .oci, name: "base", diskSizeGB: 50,
      allocatedSizeGB: 10, accessedAt: .now, state: .stopped
    )

    #expect(local.id != oci.id)
  }

  @Test("get 输出解码，含字符串形式的占用空间")
  func decodesDetails() async throws {
    let mock = MockExecutor()
    mock.enqueue(stdout: getJSON)
    let client = TartClient(executor: mock)

    let details = try await client.get(name: "sequoia")

    #expect(details.cpuCount == 4)
    #expect(details.memoryMB == 8192)
    #expect(details.memoryGB == 8.0)
    #expect(details.display == DisplayResolution(width: 1024, height: 768))
    #expect(details.diskSizeGB == 50)
    // list 里 Size 是整数，get 里却是字符串小数——这正是两者分开建模的原因。
    #expect(abs(details.allocatedSizeGB - 31.057) < 0.001)
    #expect(details.os == "darwin")
    #expect(details.state == .stopped)
  }

  @Test("未知状态值降级为 unknown 而非整体解码失败")
  func unknownStateDoesNotBreakDecoding() async throws {
    let json = listJSON.replacingOccurrences(of: "\"stopped\"", with: "\"hibernating\"")
    let mock = MockExecutor()
    mock.enqueue(stdout: json)
    let client = TartClient(executor: mock)

    let entries = try await client.list()

    // 上游新增状态时，用户仍应看得到列表。
    #expect(entries.count == 2)
    #expect(entries[0].state == .unknown)
  }

  @Test("分辨率字符串解析")
  func parsesResolution() {
    #expect(DisplayResolution(parsing: "1920x1080") == DisplayResolution(width: 1920, height: 1080))
    #expect(DisplayResolution(parsing: "1024X768") == DisplayResolution(width: 1024, height: 768))
    #expect(DisplayResolution(parsing: "garbage") == nil)
    #expect(DisplayResolution(parsing: "0x768") == nil)
    #expect(DisplayResolution(parsing: "1920x1080x60") == nil)
  }
}

@Suite("错误处理")
struct ErrorHandlingTests {
  @Test("非零退出码转成 commandFailed 并带上 stderr")
  func nonZeroExitBecomesCommandFailed() async throws {
    let mock = MockExecutor()
    mock.enqueue(stderr: "Error: the VM \"ghost\" does not exist", exitCode: 1)
    let client = TartClient(executor: mock)

    await #expect(throws: TartError.self) {
      _ = try await client.get(name: "ghost")
    }

    do {
      _ = try await TartClient(executor: {
        let m = MockExecutor()
        m.enqueue(stderr: "Error: the VM \"ghost\" does not exist", exitCode: 1)
        return m
      }()).get(name: "ghost")
      Issue.record("本应抛出错误")
    } catch let error as TartError {
      guard case let .commandFailed(_, exitCode, stderr) = error else {
        Issue.record("期望 commandFailed，实际是 \(error)")
        return
      }
      #expect(exitCode == 1)
      // stderr 必须原样带出，用户才知道到底哪里错了。
      #expect(stderr.contains("does not exist"))
    }
  }

  @Test("解码失败时保留原始输出")
  func decodingFailurePreservesRawOutput() async throws {
    let mock = MockExecutor()
    mock.enqueue(stdout: "{\"unexpected\": \"shape\"}")
    let client = TartClient(executor: mock)

    do {
      _ = try await client.get(name: "sequoia")
      Issue.record("本应抛出错误")
    } catch let error as TartError {
      guard case let .decodingFailed(_, raw, _) = error else {
        Issue.record("期望 decodingFailed，实际是 \(error)")
        return
      }
      // 没有这段原文，上游改 schema 时就无从排查。
      #expect(raw.contains("unexpected"))
    }
  }
}

@Suite("二进制定位")
struct LocatorTests {
  @Test("找不到任何候选时报告已查找的路径")
  func reportsSearchedPaths() {
    // PATH 置空，模拟从 Finder 启动的 .app —— 那种环境下确实拿不到 Homebrew 目录。
    let locator = TartLocator(searchPaths: ["/nonexistent/tart"], pathEnvironment: nil)

    do {
      _ = try locator.locate()
      Issue.record("本应抛出错误")
    } catch let error as TartError {
      guard case let .binaryNotFound(searched) = error else {
        Issue.record("期望 binaryNotFound，实际是 \(error)")
        return
      }
      #expect(searched.contains("/nonexistent/tart"))
    } catch {
      Issue.record("意外错误 \(error)")
    }
  }

  @Test("用户指定路径无效时直接报错，不静默回退")
  func userOverrideDoesNotFallBack() {
    // 即使默认路径上有可用的 tart，用户明确指定的错误路径也必须报错，
    // 否则用户会以为自己的设置生效了。
    let locator = TartLocator(
      searchPaths: TartLocator.defaultSearchPaths,
      fileExists: { _ in true },
      isExecutableFile: { $0 != "/definitely/not/here/tart" }
    )

    #expect(throws: TartError.self) {
      _ = try locator.locate(userOverride: "/definitely/not/here/tart")
    }
  }

  @Test("优先命中排在前面的已知安装位置")
  func prefersEarlierSearchPath() throws {
    let locator = TartLocator(
      searchPaths: ["/opt/homebrew/bin/tart", "/usr/local/bin/tart"],
      pathEnvironment: nil,
      isExecutableFile: { _ in true }
    )

    #expect(try locator.locate().path == "/opt/homebrew/bin/tart")
  }

  @Test("系统安装优先于 TartUI 托管运行时")
  func systemInstallBeatsManagedRuntime() throws {
    let locator = TartLocator(
      searchPaths: ["/system/tart"],
      pathEnvironment: nil,
      isExecutableFile: { $0 == "/system/tart" || $0 == "/managed/tart" },
      managedPaths: ["/managed/tart"]
    )

    let runtime = try locator.resolve()
    #expect(runtime.binaryURL.path == "/system/tart")
    #expect(runtime.source == .system)
  }

  @Test("系统和 PATH 都没有时回退到托管运行时")
  func managedRuntimeIsFallback() throws {
    let locator = TartLocator(
      searchPaths: ["/system/tart"],
      pathEnvironment: "/usr/bin:/custom/tools",
      isExecutableFile: { $0 == "/managed/tart" },
      managedPaths: ["/managed/tart"]
    )

    let runtime = try locator.resolve()
    #expect(runtime.binaryURL.path == "/managed/tart")
    #expect(runtime.source == .managed)
  }

  @Test("已知位置都落空时回退到 PATH")
  func fallsBackToPathEnvironment() throws {
    // 从终端启动时走这条路径。
    let locator = TartLocator(
      searchPaths: ["/opt/homebrew/bin/tart"],
      pathEnvironment: "/usr/bin:/custom/tools",
      isExecutableFile: { $0 == "/custom/tools/tart" }
    )

    #expect(try locator.locate().path == "/custom/tools/tart")
  }

  @Test("指定路径存在但不可执行时给出针对性错误")
  func reportsNonExecutable() {
    let locator = TartLocator(
      fileExists: { _ in true },
      isExecutableFile: { _ in false }
    )

    do {
      _ = try locator.locate(userOverride: "/some/where/tart")
      Issue.record("本应抛出错误")
    } catch let error as TartError {
      // 「找不到」和「不可执行」要分开报，处理办法完全不同（一个是装，一个是 chmod）。
      guard case .binaryNotExecutable = error else {
        Issue.record("期望 binaryNotExecutable，实际是 \(error)")
        return
      }
    } catch {
      Issue.record("意外错误 \(error)")
    }
  }
}
