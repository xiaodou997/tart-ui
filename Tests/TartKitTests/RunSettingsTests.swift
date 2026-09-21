import Foundation
import Testing
@testable import TartKit

@Suite("启动设置参数生成")
struct RunSettingsArgumentTests {
  @Test("默认设置只产出命令和虚拟机名")
  func defaultSettingsAreMinimal() {
    let settings = RunSettings()

    #expect(settings.arguments(vmName: "sequoia") == ["run", "sequoia"])
  }

  @Test("命令预览保持默认命令最简")
  func defaultCommandPreviewIsMinimal() {
    #expect(RunSettings().command(vmName: "dev") == "tart run dev")
  }

  @Test("命令预览会对含空格的参数做 shell 引号")
  func commandPreviewQuotesShellArguments() {
    var settings = RunSettings()
    settings.noGraphics = true
    settings.noClipboard = true
    settings.suspendable = true
    settings.directoryShares = ["work:/Users/me/My Project:ro"]
    settings.network = .bridged(interfaces: ["en0"])

    #expect(settings.arguments(vmName: "dev vm") == [
      "run",
      "dev vm",
      "--no-graphics",
      "--no-clipboard",
      "--suspendable",
      "--dir=work:/Users/me/My Project:ro",
      "--net-bridged=en0",
    ])

    #expect(
      settings.command(vmName: "dev vm")
        == "tart run 'dev vm' --no-graphics --no-clipboard --suspendable '--dir=work:/Users/me/My Project:ro' --net-bridged=en0"
    )
  }

  @Test("命令预览正确转义单引号")
  func commandPreviewEscapesSingleQuotes() {
    #expect(
      RunSettings().command(vmName: "it's here")
        == "tart run 'it'\\''s here'"
    )
  }

  @Test("当前界面支持的启动开关都会映射到命令")
  func supportedLaunchFlags() {
    let settings = RunSettings(
      noGraphics: true,
      vnc: true,
      noClipboard: true,
      suspendable: true,
      recovery: true
    )

    let arguments = settings.arguments(vmName: "vm")

    #expect(arguments.contains("--no-graphics"))
    #expect(arguments.contains("--vnc"))
    #expect(arguments.contains("--no-clipboard"))
    #expect(arguments.contains("--suspendable"))
    #expect(arguments.contains("--recovery"))
  }

  @Test("目录共享可以有多个，空条目会被跳过")
  func directoryShares() {
    let settings = RunSettings(directoryShares: ["", "~/src", "build:~/out:ro"])

    let arguments = settings.arguments(vmName: "vm")

    #expect(arguments.contains("--dir=~/src"))
    #expect(arguments.contains("--dir=build:~/out:ro"))
    #expect(!arguments.contains("--dir="))
  }
}

@Suite("网络启动设置")
struct RunSettingsNetworkTests {
  @Test("默认共享网络不产出任何参数")
  func sharedProducesNothing() {
    let settings = RunSettings(network: .shared)

    #expect(settings.arguments(vmName: "vm") == ["run", "vm"])
  }

  @Test("桥接网络支持多张适配器并重复生成参数")
  func bridged() {
    let settings = RunSettings(network: .bridged(interfaces: ["en0", "en5"]))

    let arguments = settings.arguments(vmName: "vm")
    #expect(arguments.contains("--net-bridged=en0"))
    #expect(arguments.contains("--net-bridged=en5"))
    #expect(arguments.filter { $0.hasPrefix("--net-bridged=") }.count == 2)
  }

  @Test("仅宿主机网络")
  func hostOnly() {
    let settings = RunSettings(network: .hostOnly)

    #expect(settings.arguments(vmName: "vm").contains("--net-host"))
  }

  @Test("Softnet 使用 Tart 默认模式")
  func softnetUsesDefaults() {
    let settings = RunSettings(network: .softnet)

    #expect(settings.arguments(vmName: "vm") == ["run", "vm", "--net-softnet"])
  }

  @Test("网络模式互斥")
  func modesAreMutuallyExclusive() {
    let modes: [NetworkMode] = [
      .shared,
      .bridged(interfaces: ["en0", "en5"]),
      .hostOnly,
      .softnet,
    ]

    for mode in modes {
      let arguments = RunSettings(network: mode).arguments(vmName: "vm")
      let families = Set(arguments.compactMap { argument -> String? in
        if argument.hasPrefix("--net-bridged=") { return "bridged" }
        if argument == "--net-host" { return "host" }
        if argument == "--net-softnet" { return "softnet" }
        return nil
      })
      #expect(families.count <= 1)
    }
  }

  @Test("桥接模式没有适配器时阻止保存或启动")
  func emptyBridgeInterfaceIsBlocking() {
    let settings = RunSettings(network: .bridged(interfaces: []))

    #expect(!settings.arguments(vmName: "vm").contains { $0.hasPrefix("--net-bridged") })
    #expect(settings.hasBlockingIssues)
  }

  @Test("重复的桥接适配器属于阻断性错误")
  func duplicateBridgeInterfaceIsBlocking() {
    let settings = RunSettings(network: .bridged(interfaces: ["en0", "en0"]))

    #expect(settings.hasBlockingIssues)
  }

  @Test("桥接 IP 查询使用 ARP，其余模式使用 DHCP")
  func ipResolverFollowsNetworkMode() {
    #expect(RunSettings(network: .bridged(interfaces: ["en0"])).ipResolver == .arp)
    #expect(RunSettings(network: .shared).ipResolver == .dhcp)
    #expect(RunSettings(network: .hostOnly).ipResolver == .dhcp)
    #expect(RunSettings(network: .softnet).ipResolver == .dhcp)
  }

  @Test("当前网络模式都可以 JSON 往返")
  func networkModesRoundTrip() throws {
    let modes: [NetworkMode] = [
      .shared,
      .bridged(interfaces: ["en0", "en5"]),
      .hostOnly,
      .softnet,
    ]

    for mode in modes {
      let data = try JSONEncoder().encode(mode)
      let decoded = try JSONDecoder().decode(NetworkMode.self, from: data)
      #expect(decoded == mode)
    }
  }
}

@Suite("启动设置校验")
struct RunSettingsValidationTests {
  @Test("无图形且无 VNC 只是提醒，不阻断")
  func headlessWithoutVNCIsAdvisory() {
    let settings = RunSettings(noGraphics: true)

    #expect(!settings.hasBlockingIssues)
    #expect(settings.validate().contains { !$0.isBlocking })
  }

  @Test("默认设置没有任何告警")
  func defaultSettingsAreClean() {
    #expect(RunSettings().validate().isEmpty)
  }
}

@Suite("启动设置存储")
struct RunSettingsStoreTests {
  private func makeStore() -> RunSettingsStore {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("tartui-tests-\(UUID().uuidString)")
      .appendingPathComponent("run-settings.json")
    return RunSettingsStore(fileURL: url)
  }

  @Test("文件不存在时返回空集合")
  func missingFileYieldsEmpty() throws {
    let store = makeStore()

    #expect(try store.load().settingsByVM.isEmpty)
  }

  @Test("存取往返")
  func roundTrip() throws {
    let store = makeStore()
    defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }

    var collection = RunSettingsCollection()
    collection.set(
      RunSettings(noGraphics: true, network: .softnet),
      for: "sequoia"
    )
    try store.save(collection)

    let restored = try store.load().settings(for: "sequoia")

    #expect(restored.noGraphics)
    #expect(restored.arguments(vmName: "sequoia") == [
      "run", "sequoia", "--no-graphics", "--net-softnet"
    ])
  }

  @Test("同一台 VM 保存时直接替换")
  func setReplaces() {
    var collection = RunSettingsCollection()
    collection.set(RunSettings(noGraphics: true), for: "vm")
    collection.set(RunSettings(vnc: true), for: "vm")

    let settings = collection.settings(for: "vm")
    #expect(!settings.noGraphics)
    #expect(settings.vnc)
    #expect(collection.settingsByVM.count == 1)
  }

  @Test("虚拟机改名时启动设置跟着搬迁")
  func renameMovesSettings() {
    var collection = RunSettingsCollection()
    collection.set(RunSettings(noClipboard: true), for: "old-name")

    collection.rename(vmName: "old-name", to: "new-name")

    #expect(collection.settingsByVM["old-name"] == nil)
    #expect(collection.settings(for: "new-name").noClipboard)
  }

  @Test("删除虚拟机会清掉启动设置")
  func removeClearsVM() {
    var collection = RunSettingsCollection()
    collection.set(RunSettings(noGraphics: true), for: "vm")

    collection.remove(for: "vm")

    #expect(collection.settingsByVM["vm"] == nil)
  }

  @Test("清理掉已不存在虚拟机的启动设置")
  func pruneRemovesOrphans() {
    var collection = RunSettingsCollection()
    collection.set(RunSettings(), for: "still-here")
    collection.set(RunSettings(), for: "deleted-elsewhere")

    collection.prune(keepingOnly: ["still-here"])

    #expect(collection.settingsByVM["still-here"] != nil)
    #expect(collection.settingsByVM["deleted-elsewhere"] == nil)
  }

  @Test("没有配置过的虚拟机使用默认启动设置")
  func fallsBackToDefaultSettings() {
    let collection = RunSettingsCollection()

    #expect(collection.settings(for: "never-configured").arguments(vmName: "vm") == ["run", "vm"])
  }
}
