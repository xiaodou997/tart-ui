import Foundation
import Testing
@testable import TartKit

@Suite("Run Profile 参数生成")
struct RunProfileArgumentTests {
  @Test("默认配置只产出命令和虚拟机名")
  func defaultProfileIsMinimal() {
    let profile = RunProfile()

    // 默认值不该产出任何参数：既没必要，也让用户在日志里看不清自己改了什么。
    #expect(profile.arguments(vmName: "sequoia") == ["run", "sequoia"])
  }

  @Test("命令预览保持默认命令最简")
  func defaultCommandPreviewIsMinimal() {
    #expect(RunProfile().command(vmName: "dev") == "tart run dev")
  }

  @Test("命令预览会对含空格的参数做 shell 引号")
  func commandPreviewQuotesShellArguments() {
    var profile = RunProfile()
    profile.noGraphics = true
    profile.noClipboard = true
    profile.suspendable = true
    profile.directoryShares = ["work:/Users/me/My Project:ro"]
    profile.network = .bridged(interfaces: ["Wi-Fi"])

    #expect(profile.arguments(vmName: "dev vm") == [
      "run",
      "dev vm",
      "--no-graphics",
      "--no-clipboard",
      "--suspendable",
      "--dir=work:/Users/me/My Project:ro",
      "--net-bridged=Wi-Fi",
    ])

    #expect(
      profile.command(vmName: "dev vm")
        == "tart run 'dev vm' --no-graphics --no-clipboard --suspendable '--dir=work:/Users/me/My Project:ro' --net-bridged=Wi-Fi"
    )
  }

  @Test("命令预览正确转义单引号")
  func commandPreviewEscapesSingleQuotes() {
    #expect(
      RunProfile().command(vmName: "it's here")
        == "tart run 'it'\\''s here'"
    )
  }

  @Test("显示与输入相关的开关")
  func displayFlags() {
    let profile = RunProfile(
      noGraphics: true,
      captureSystemKeys: true,
      noTrackpad: true,
      noPointer: true,
      noKeyboard: true
    )

    let arguments = profile.arguments(vmName: "vm")

    #expect(arguments.contains("--no-graphics"))
    #expect(arguments.contains("--capture-system-keys"))
    #expect(arguments.contains("--no-trackpad"))
    #expect(arguments.contains("--no-pointer"))
    #expect(arguments.contains("--no-keyboard"))
  }

  @Test("设备相关的开关")
  func deviceFlags() {
    let profile = RunProfile(
      noAudio: true,
      noClipboard: true,
      suspendable: true,
      nested: true,
      recovery: true
    )

    let arguments = profile.arguments(vmName: "vm")

    #expect(arguments.contains("--no-audio"))
    #expect(arguments.contains("--no-clipboard"))
    #expect(arguments.contains("--suspendable"))
    #expect(arguments.contains("--nested"))
    #expect(arguments.contains("--recovery"))
  }

  @Test("磁盘与目录共享用 = 形式，且可以有多个")
  func disksAndShares() {
    let profile = RunProfile(
      disks: ["/tmp/data.img", "/tmp/ubuntu.iso:ro"],
      rootDiskOptions: "caching=cached,sync=none",
      directoryShares: ["~/src", "build:~/out:ro"],
      rosettaTag: "rosetta"
    )

    let arguments = profile.arguments(vmName: "vm")

    #expect(arguments.contains("--disk=/tmp/data.img"))
    #expect(arguments.contains("--disk=/tmp/ubuntu.iso:ro"))
    #expect(arguments.contains("--root-disk-opts=caching=cached,sync=none"))
    #expect(arguments.contains("--dir=~/src"))
    #expect(arguments.contains("--dir=build:~/out:ro"))
    #expect(arguments.contains("--rosetta=rosetta"))
  }

  @Test("空字符串的磁盘和共享条目会被跳过")
  func skipsEmptyEntries() {
    // 界面上新增一行还没填内容时会出现空串，不能把 `--disk=` 传给 tart。
    let profile = RunProfile(disks: ["", "/tmp/a.img"], directoryShares: [""])

    let arguments = profile.arguments(vmName: "vm")

    #expect(arguments.contains("--disk=/tmp/a.img"))
    #expect(!arguments.contains("--disk="))
    #expect(!arguments.contains("--dir="))
  }

  @Test("串口路径用分离的参数形式")
  func serialOptions() {
    let profile = RunProfile(serial: true, serialPath: "/dev/ttys001")

    let arguments = profile.arguments(vmName: "vm")

    #expect(arguments.contains("--serial"))
    // 这个选项 tart 接受空格分隔形式。
    let index = arguments.firstIndex(of: "--serial-path")
    #expect(index != nil)
    if let index {
      #expect(arguments[index + 1] == "/dev/ttys001")
    }
  }
}

@Suite("网络模式")
struct NetworkModeTests {
  @Test("默认共享网络不产出任何参数")
  func sharedProducesNothing() {
    let profile = RunProfile(network: .shared)

    #expect(profile.arguments(vmName: "vm") == ["run", "vm"])
  }

  @Test("桥接网络支持多张适配器并重复生成参数")
  func bridged() {
    let profile = RunProfile(network: .bridged(interfaces: ["en0", "en5"]))

    let arguments = profile.arguments(vmName: "vm")
    #expect(arguments.contains("--net-bridged=en0"))
    #expect(arguments.contains("--net-bridged=en5"))
    #expect(arguments.filter { $0.hasPrefix("--net-bridged=") }.count == 2)
  }

  @Test("仅宿主机网络")
  func hostOnly() {
    let profile = RunProfile(network: .hostOnly)

    #expect(profile.arguments(vmName: "vm").contains("--net-host"))
  }

  @Test("Softnet 及其子选项")
  func softnetWithOptions() {
    let profile = RunProfile(network: .softnet(SoftnetOptions(
      allowedCIDRs: ["192.168.0.0/24", "10.0.0.0/16"],
      blockedCIDRs: ["66.66.0.0/16"],
      exposedPorts: [
        PortForward(hostPort: 2222, guestPort: 22),
        PortForward(hostPort: 8080, guestPort: 80),
      ]
    )))

    let arguments = profile.arguments(vmName: "vm")

    #expect(arguments.contains("--net-softnet"))
    #expect(arguments.contains("--net-softnet-allow=192.168.0.0/24,10.0.0.0/16"))
    #expect(arguments.contains("--net-softnet-block=66.66.0.0/16"))
    #expect(arguments.contains("--net-softnet-expose=2222:22,8080:80"))
  }

  @Test("网络模式互斥：多张桥接网卡仍然只属于一种网络模式")
  func modesAreMutuallyExclusive() {
    let modes: [NetworkMode] = [
      .shared,
      .bridged(interfaces: ["en0", "en5"]),
      .hostOnly,
      .softnet(SoftnetOptions()),
    ]

    for mode in modes {
      let arguments = RunProfile(network: mode).arguments(vmName: "vm")
      let families = Set(arguments.compactMap { argument -> String? in
        if argument.hasPrefix("--net-bridged=") { return "bridged" }
        if argument == "--net-host" { return "host" }
        if argument == "--net-softnet" { return "softnet" }
        return nil
      })
      #expect(families.count <= 1, "模式 \(mode) 产出了多种网络参数：\(families)")
    }
  }

  @Test("桥接模式没有适配器时阻止保存或启动")
  func emptyBridgeInterfaceIsBlocking() {
    let profile = RunProfile(network: .bridged(interfaces: []))

    #expect(!profile.arguments(vmName: "vm").contains { $0.hasPrefix("--net-bridged") })
    #expect(profile.hasBlockingIssues)
  }

  @Test("重复的桥接适配器属于阻断性错误")
  func duplicateBridgeInterfaceIsBlocking() {
    let profile = RunProfile(network: .bridged(interfaces: ["en0", "en0"]))

    #expect(profile.hasBlockingIssues)
  }

  @Test("旧版单桥接网卡 JSON 自动迁移")
  func legacyBridgeProfileDecodes() throws {
    let data = Data(#"{"bridged":{"interface":"en0"}}"#.utf8)

    let mode = try JSONDecoder().decode(NetworkMode.self, from: data)

    #expect(mode == .bridged(interfaces: ["en0"]))
  }

  @Test("多桥接网卡 JSON 可以往返")
  func multipleBridgeInterfacesRoundTrip() throws {
    let original = NetworkMode.bridged(interfaces: ["en0", "en5"])

    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(NetworkMode.self, from: data)

    #expect(decoded == original)
  }
}

@Suite("Run Profile 校验")
struct RunProfileValidationTests {
  @Test("两种 VNC 同时启用属于阻断性错误")
  func conflictingVNC() {
    let profile = RunProfile(vnc: true, vncExperimental: true)

    let warnings = profile.validate()

    #expect(profile.hasBlockingIssues)
    #expect(warnings.contains { $0.isBlocking })
  }

  @Test("无图形且无 VNC 只是提醒，不阻断")
  func headlessWithoutVNCIsAdvisory() {
    let profile = RunProfile(noGraphics: true)

    #expect(!profile.hasBlockingIssues)
    #expect(profile.validate().contains { !$0.isBlocking })
  }

  @Test("端口越界属于阻断性错误")
  func invalidPortIsBlocking() {
    let profile = RunProfile(network: .softnet(SoftnetOptions(
      allowedCIDRs: ["0.0.0.0/0"],
      exposedPorts: [PortForward(hostPort: 70000, guestPort: 22)]
    )))

    #expect(profile.hasBlockingIssues)
  }

  @Test("默认配置没有任何告警")
  func defaultProfileIsClean() {
    #expect(RunProfile().validate().isEmpty)
  }

  @Test("端口转发但未放行网段会给出提醒")
  func portForwardWithoutAllowWarns() {
    let profile = RunProfile(network: .softnet(SoftnetOptions(
      exposedPorts: [PortForward(hostPort: 2222, guestPort: 22)]
    )))

    let warnings = profile.validate()

    #expect(warnings.contains { !$0.isBlocking })
    #expect(!profile.hasBlockingIssues)
  }
}

@Suite("Profile 存储")
struct RunProfileStoreTests {
  /// 每个用例用独立的临时文件，互不干扰。
  private func makeStore() -> RunProfileStore {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("tartui-tests-\(UUID().uuidString)")
      .appendingPathComponent("run-profiles.json")
    return RunProfileStore(fileURL: url)
  }

  @Test("文件不存在时返回空集合而不是报错")
  func missingFileYieldsEmpty() throws {
    let store = makeStore()

    #expect(try store.load().profilesByVM.isEmpty)
  }

  @Test("存取往返")
  func roundTrip() throws {
    let store = makeStore()
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }

    var collection = ProfileCollection()
    let profile = RunProfile(
      name: "无图形测试",
      noGraphics: true,
      network: .softnet(SoftnetOptions(exposedPorts: [PortForward(hostPort: 2222, guestPort: 22)]))
    )
    collection.upsert(profile, for: "sequoia")
    try store.save(collection)

    let loaded = try store.load()
    let restored = loaded.profiles(for: "sequoia")

    #expect(restored.count == 1)
    #expect(restored[0].name == "无图形测试")
    #expect(restored[0].noGraphics)
    // 带关联值的枚举也要能正确往返。
    #expect(restored[0].arguments(vmName: "sequoia").contains("--net-softnet-expose=2222:22"))
  }

  @Test("同 ID 的 profile 是更新而非追加")
  func upsertReplaces() {
    var collection = ProfileCollection()
    var profile = RunProfile(name: "原名")
    collection.upsert(profile, for: "vm")

    profile.name = "改名后"
    collection.upsert(profile, for: "vm")

    #expect(collection.profiles(for: "vm").count == 1)
    #expect(collection.profiles(for: "vm")[0].name == "改名后")
  }

  @Test("虚拟机改名时 profile 跟着搬迁")
  func renameMovesProfiles() {
    var collection = ProfileCollection()
    collection.upsert(RunProfile(name: "开发"), for: "old-name")

    collection.rename(vmName: "old-name", to: "new-name")

    // 不搬迁的话，用户精心配的启动参数就凭空消失了。
    #expect(collection.profiles(for: "old-name").isEmpty)
    #expect(collection.profiles(for: "new-name").count == 1)
    #expect(collection.profiles(for: "new-name")[0].name == "开发")
  }

  @Test("删除虚拟机会清掉它的 profile")
  func removeAllClearsVM() {
    var collection = ProfileCollection()
    collection.upsert(RunProfile(), for: "vm")

    collection.removeAll(for: "vm")

    #expect(collection.profiles(for: "vm").isEmpty)
  }

  @Test("清理掉已不存在的虚拟机的 profile")
  func pruneRemovesOrphans() {
    // 用户可能绕过界面直接 tart delete，需要这个兜底。
    var collection = ProfileCollection()
    collection.upsert(RunProfile(), for: "still-here")
    collection.upsert(RunProfile(), for: "deleted-elsewhere")

    collection.prune(keepingOnly: ["still-here"])

    #expect(collection.profiles(for: "still-here").count == 1)
    #expect(collection.profiles(for: "deleted-elsewhere").isEmpty)
  }

  @Test("移除最后一个 profile 后不留下空条目")
  func removingLastProfileDropsKey() {
    var collection = ProfileCollection()
    let profile = RunProfile()
    collection.upsert(profile, for: "vm")

    collection.remove(profileID: profile.id, for: "vm")

    #expect(collection.profilesByVM["vm"] == nil)
  }

  @Test("没有配置过的虚拟机取到一份默认 profile")
  func fallsBackToDefaultProfile() {
    let collection = ProfileCollection()

    // 让「从没配置过」和「配置过」在调用方看来一致，省掉各处空值判断。
    let profile = collection.profile(for: "never-configured", id: nil)

    #expect(profile.arguments(vmName: "vm") == ["run", "vm"])
  }
}
