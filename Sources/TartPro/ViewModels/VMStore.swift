import Foundation
import Observation
import TartKit

/// 应用的状态中枢：虚拟机列表、启动配置、运行中的会话。
@Observable
@MainActor
final class VMStore {
  private(set) var entries: [VMListEntry] = []
  private(set) var isLoading = false
  private(set) var loadError: String?

  /// tart 不可用时为 nil，界面据此显示引导页。
  private(set) var client: TartClient?
  private(set) var tartVersion: String?

  /// 由 TartPro 启动的虚拟机进程。tart 可用后才会建立。
  private(set) var sessions: RunSessionManager?

  /// 创建、克隆这类长时操作。
  let operations = OperationCenter()

  private(set) var profiles = ProfileCollection()
  private var profileStore: RunProfileStore?

  /// 操作失败时给用户看的提示，与列表加载错误分开。
  var actionError: String?

  // MARK: - 启动自检

  func bootstrap(userOverride: String? = nil) async {
    do {
      let client = try TartClient(userOverride: userOverride)
      self.tartVersion = try await client.version()
      self.client = client
      self.sessions = RunSessionManager(client: client)
      self.loadError = nil

      loadProfiles()
      await refresh()
    } catch {
      // 定位失败不是「加载出错」，而是「还没配好」，界面应给出安装/指路引导。
      self.client = nil
      self.sessions = nil
      self.loadError = error.localizedDescription
    }
  }

  func refresh() async {
    guard let client else { return }

    isLoading = true
    defer { isLoading = false }

    do {
      entries = try await client.list()
      loadError = nil
    } catch {
      loadError = error.localizedDescription
    }
  }

  var localEntries: [VMListEntry] {
    entries.filter { $0.source == .local }
  }

  var ociEntries: [VMListEntry] {
    entries.filter { $0.source == .oci }
  }

  func entry(id: VMListEntry.ID?) -> VMListEntry? {
    guard let id else { return nil }
    return entries.first { $0.id == id }
  }

  // MARK: - 启动配置

  private func loadProfiles() {
    do {
      let store = try RunProfileStore()
      profileStore = store
      profiles = try store.load()
    } catch {
      // 配置读不出来不该挡住整个应用，退回空集合，用户重新配置即可。
      profileStore = try? RunProfileStore()
      profiles = ProfileCollection()
      actionError = "启动配置读取失败，已重置：\(error.localizedDescription)"
    }
  }

  func profile(for vmName: String, id: UUID?) -> RunProfile {
    profiles.profile(for: vmName, id: id)
  }

  func saveProfile(_ profile: RunProfile, for vmName: String) {
    profiles.upsert(profile, for: vmName)
    persistProfiles()
  }

  func deleteProfile(id: UUID, for vmName: String) {
    profiles.remove(profileID: id, for: vmName)
    persistProfiles()
  }

  private func persistProfiles() {
    guard let profileStore else { return }
    do {
      try profileStore.save(profiles)
    } catch {
      actionError = "启动配置保存失败：\(error.localizedDescription)"
    }
  }

  // MARK: - 生命周期操作

  func start(vmName: String, profile: RunProfile) {
    guard let sessions else { return }

    if profile.hasBlockingIssues {
      // 有阻断性问题时不该白跑一趟让 tart 报错。
      actionError = "启动配置有冲突，请先修正后再启动。"
      return
    }

    sessions.start(vmName: vmName, profile: profile)

    // tart run 要过一会儿才会把状态写进虚拟机目录，延迟刷新一次。
    Task {
      try? await Task.sleep(for: .seconds(2))
      await refresh()
    }
  }

  func stop(vmName: String) async {
    guard let sessions else { return }
    do {
      try await sessions.stop(vmName: vmName)
      await refresh()
    } catch {
      actionError = error.localizedDescription
    }
  }

  func suspend(vmName: String) async {
    guard let sessions else { return }
    do {
      try await sessions.suspend(vmName: vmName)
      await refresh()
    } catch {
      // 未以 --suspendable 启动的虚拟机会走到这里，tart 的报错已经说清了原因。
      actionError = error.localizedDescription
    }
  }

  /// TartPro 是否掌握着这台虚拟机的进程。
  ///
  /// 用户可能在终端里直接 `tart run`，那样的虚拟机同样显示为运行中，
  /// 但 TartPro 拿不到它的进程句柄，只能请求关机、不能强制结束。
  func isManagedByApp(_ vmName: String) -> Bool {
    sessions?.isManaged(vmName) ?? false
  }

  // MARK: - 创建与克隆

  func createVM(
    name: String,
    source: VMCreationSource,
    diskSizeGB: UInt?,
    diskFormat: DiskFormat?
  ) {
    guard let client else { return }

    let title: String
    switch source {
    case .linux: title = "创建 Linux 虚拟机「\(name)」"
    case .macOSFromIPSW: title = "创建 macOS 虚拟机「\(name)」"
    }

    operations.run(
      title: title,
      stream: { client.create(name: name, source: source, diskSizeGB: diskSizeGB, diskFormat: diskFormat) },
      onSuccess: { [weak self] in await self?.refresh() }
    )
  }

  func cloneVM(source: String, newName: String, insecure: Bool = false, concurrency: UInt? = nil) {
    guard let client else { return }

    operations.run(
      title: "克隆「\(source)」→「\(newName)」",
      stream: { client.clone(source: source, newName: newName, insecure: insecure, concurrency: concurrency) },
      onSuccess: { [weak self] in await self?.refresh() }
    )
  }

  // MARK: - 修改与删除

  func updateConfig(
    name: String,
    cpuCount: Int? = nil,
    memoryMB: Int? = nil,
    display: DisplayResolution? = nil,
    displayUnit: DisplayUnit? = nil,
    randomMAC: Bool = false,
    randomSerial: Bool = false,
    diskSizeGB: Int? = nil
  ) async {
    guard let client else { return }
    do {
      try await client.set(
        name: name,
        cpuCount: cpuCount,
        memoryMB: memoryMB,
        display: display,
        displayUnit: displayUnit,
        randomMAC: randomMAC,
        randomSerial: randomSerial,
        diskSizeGB: diskSizeGB
      )
      await refresh()
    } catch {
      actionError = error.localizedDescription
    }
  }

  func rename(name: String, to newName: String) async {
    guard let client else { return }
    do {
      try await client.rename(name: name, to: newName)
      // 启动配置要跟着搬迁，否则用户配好的参数会失联。
      profiles.rename(vmName: name, to: newName)
      persistProfiles()
      await refresh()
    } catch {
      actionError = error.localizedDescription
    }
  }

  /// 删除虚拟机。不可撤销，调用前必须已经过用户确认。
  func delete(names: [String]) async {
    guard let client else { return }
    do {
      try await client.delete(names: names)
      for name in names {
        profiles.removeAll(for: name)
      }
      persistProfiles()
      await refresh()
    } catch {
      actionError = error.localizedDescription
    }
  }

  // MARK: - 镜像仓库

  func pull(reference: String, insecure: Bool = false, concurrency: UInt? = nil) {
    guard let client else { return }

    operations.run(
      title: "拉取「\(reference)」",
      stream: { client.pull(remoteName: reference, insecure: insecure, concurrency: concurrency) },
      onSuccess: { [weak self] in await self?.refresh() }
    )
  }

  func push(
    localName: String,
    remoteNames: [String],
    insecure: Bool = false,
    concurrency: UInt? = nil,
    chunkSizeMB: Int? = nil,
    labels: [ImageLabel] = [],
    populateCache: Bool = false
  ) {
    guard let client else { return }

    let target = remoteNames.count == 1 ? remoteNames[0] : "\(remoteNames.count) 个目标"
    operations.run(
      title: "推送「\(localName)」→ \(target)",
      stream: {
        client.push(
          localName: localName,
          remoteNames: remoteNames,
          insecure: insecure,
          concurrency: concurrency,
          chunkSizeMB: chunkSizeMB,
          labels: labels,
          populateCache: populateCache
        )
      },
      onSuccess: { [weak self] in await self?.refresh() }
    )
  }

  /// 登录仓库。成功返回 nil，失败返回错误描述。
  ///
  /// 不抛错而是返回描述，因为登录表单要在自己的界面上就地显示结果。
  func login(
    host: String,
    username: String,
    password: String,
    insecure: Bool,
    validate: Bool
  ) async -> String? {
    guard let client else { return "tart 不可用。" }
    do {
      try await client.login(
        host: host, username: username, password: password,
        insecure: insecure, validate: validate
      )
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  func logout(host: String) async -> String? {
    guard let client else { return "tart 不可用。" }
    do {
      try await client.logout(host: host)
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  // MARK: - 导入导出

  func exportVM(name: String, to path: String) {
    guard let client else { return }

    operations.run(
      title: "导出「\(name)」",
      stream: { client.export(name: name, to: path) }
    )
  }

  func importVM(from path: String, name: String) {
    guard let client else { return }

    operations.run(
      title: "导入「\(name)」",
      stream: { client.importVM(from: path, name: name) },
      onSuccess: { [weak self] in await self?.refresh() }
    )
  }

  // MARK: - 清理

  /// 预测清理会删掉什么。tart 没有 dry-run，这里复刻它的选择逻辑。
  func prunePlan(target: PruneTarget, olderThanDays: UInt?, spaceBudgetGB: UInt?) -> PrunePlanner.Plan {
    let candidates = target == .caches ? ociEntries : localEntries
    return PrunePlanner.plan(
      entries: candidates,
      target: target,
      olderThanDays: olderThanDays,
      spaceBudgetGB: spaceBudgetGB
    )
  }

  func prune(target: PruneTarget, olderThanDays: UInt?, spaceBudgetGB: UInt?) async {
    guard let client else { return }
    do {
      try await client.prune(
        target: target, olderThanDays: olderThanDays, spaceBudgetGB: spaceBudgetGB
      )
      await refresh()
      pruneOrphanProfiles()
    } catch {
      actionError = error.localizedDescription
    }
  }

  // MARK: - 网络与远程执行

  /// 查询虚拟机 IP。失败返回 nil，由调用方决定怎么展示。
  func ipAddress(for vmName: String, waitSeconds: UInt? = nil) async -> String? {
    guard let client else { return nil }
    return try? await client.ip(name: vmName, waitSeconds: waitSeconds)
  }

  /// 在虚拟机内执行命令。
  ///
  /// 需要客户机内装有 tart-guest-agent，否则会失败。
  func exec(vmName: String, command: [String]) async -> CommandResult? {
    guard let client else { return nil }
    do {
      return try await client.exec(name: vmName, command: command)
    } catch {
      actionError = error.localizedDescription
      return nil
    }
  }

  /// 清理掉已经不存在的虚拟机的启动配置。
  ///
  /// 用户可能绕过界面直接在终端 `tart delete`，需要这个兜底。
  func pruneOrphanProfiles() {
    let existing = Set(entries.map(\.name))
    guard !existing.isEmpty else { return }
    profiles.prune(keepingOnly: existing)
    persistProfiles()
  }
}
