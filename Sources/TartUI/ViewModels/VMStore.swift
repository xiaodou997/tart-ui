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
  private(set) var runtime: TartRuntime?
  private(set) var tartVersion: String?
  private(set) var isInstallingRuntime = false
  private(set) var runtimeInstallError: String?

  var runtimeSource: TartRuntimeSource? { runtime?.source }

  /// 由 TartUI 启动的虚拟机进程。tart 可用后才会建立。
  ///
  /// 会话协调器是 UI 与 Tart runtime 之间唯一的生命周期边界；视图不直接
  /// 持有或启动 Foundation.Process。
  private(set) var runtimeSessions: VMRuntimeCoordinator?

  /// 创建、克隆这类长时操作。
  let operations = OperationCenter()

  private(set) var profiles = ProfileCollection()
  private var profileStore: RunProfileStore?

  /// 操作失败时给用户看的提示，与列表加载错误分开。
  var actionError: String?

  private var pollingTask: Task<Void, Never>?
  private var watcher: DirectoryWatcher?

  /// 轮询间隔。虚拟机的状态变化不需要毫秒级响应，间隔太短只是白耗 IO。
  private let pollInterval: Duration = .seconds(3)

  // MARK: - 启动自检

  func bootstrap(userOverride: String? = nil) async {
    if let runtimeSessions, !runtimeSessions.activeVMNames.isEmpty {
      actionError = L10n.text("Stop all running VMs before changing the Tart runtime.")
      return
    }

    do {
      let runtime = try TartLocator().resolve(userOverride: userOverride)
      // 内置 tart 现在只是个普通命令行工具，不需要任何身份标记环境变量。
      let client = TartClient(runtime: runtime)
      self.tartVersion = try await client.version()
      self.runtime = runtime
      self.client = client
      // 虚拟机跑在本进程内，不再需要 runtime 适配器；这里的 TartClient 只
      // 负责 list / clone / pull 这类一次性命令。
      self.runtimeSessions = VMRuntimeCoordinator(
        onSessionFinished: { [weak self] _ in
          Task { @MainActor [weak self] in
            await self?.refresh()
          }
        }
      )
      // bootstrap 可能在 App 注入 windowOpener 之后才跑完，这里补挂一次。
      self.runtimeSessions?.onWindowRequested = windowOpener
      self.loadError = nil
      self.runtimeInstallError = nil

      loadProfiles()
      await refresh()
      pruneOrphanProfiles()
      startAutoSync()
    } catch {
      // 定位失败不是「加载出错」，而是「还没配好」，界面应给出安装/指路引导。
      self.client = nil
      self.runtime = nil
      self.tartVersion = nil
      self.runtimeSessions = nil
      self.loadError = error.localizedDescription
    }
  }

  /// 下载并启用官方最新 Tart runtime，然后重新加载整个应用状态。
  ///
  /// 运行时安装在 TartUI 的 Application Support 目录，不会覆盖 App bundle，
  /// 因此正式签名的 App 更新和用户自行更新 runtime 可以并存。
  func installLatestRuntime() async {
    guard !isInstallingRuntime else { return }
    guard runtimeSessions?.activeVMNames.isEmpty ?? true else {
      runtimeInstallError = L10n.text("Stop all running VMs before updating Tart.")
      return
    }

    isInstallingRuntime = true
    runtimeInstallError = nil
    defer { isInstallingRuntime = false }

    do {
      _ = try await TartRuntimeInstaller().installLatest()
      await bootstrap()
    } catch {
      runtimeInstallError = error.localizedDescription
      loadError = error.localizedDescription
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

  // MARK: - 自动同步

  /// 启动状态自动同步。
  ///
  /// 两条通道合并：
  /// - **轮询** `tart list` 拿运行状态。状态判断以 tart 自己的结论为准，
  ///   比我们去猜文件系统里的标志可靠。
  /// - **目录监听** 即时感知虚拟机增删。用户可能在终端里直接操作，
  ///   只靠轮询最长要等一整个周期才更新，界面会显得发木。
  private func startAutoSync() {
    stopAutoSync()

    pollingTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        try? await Task.sleep(for: self.pollInterval)
        guard !Task.isCancelled else { return }
        await self.refreshQuietly()
      }
    }

    let watcher = DirectoryWatcher(url: DirectoryWatcher.tartVMsDirectory()) { [weak self] in
      Task { @MainActor in
        await self?.refreshQuietly()
      }
    }
    // 目录不存在时监听会失败，此时退回纯轮询即可，不必打扰用户。
    watcher.start()
    self.watcher = watcher
  }

  func stopAutoSync() {
    pollingTask?.cancel()
    pollingTask = nil
    watcher?.stop()
    watcher = nil
  }

  /// 后台刷新：不显示加载指示，失败也不弹错。
  ///
  /// 自动刷新是背景行为，因为一次网络抖动或临时锁冲突就打断用户操作是很烦人的。
  /// 真正的错误会在用户主动操作时暴露出来。
  private func refreshQuietly() async {
    guard let client else { return }
    guard let fresh = try? await client.list() else { return }

    // 内容没变就不要碰 entries，避免无谓地触发整个列表重绘。
    if fresh != entries {
      entries = fresh
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
      actionError = L10n.format("Failed to read run profiles; they were reset: %@", error.localizedDescription)
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
      actionError = L10n.format("Failed to save run profiles: %@", error.localizedDescription)
    }
  }

  // MARK: - 生命周期操作

  /// 打开虚拟机窗口的方式，由 App 层注入（SwiftUI 的 openWindow 只能在
  /// 视图里取到）。协调器通过它把窗口叫出来，自己不依赖任何 UI 类型。
  var windowOpener: (@MainActor @Sendable (String) -> Void)? {
    didSet { runtimeSessions?.onWindowRequested = windowOpener }
  }

  /// 某台虚拟机是否要把 Cmd+Tab 这类系统快捷键送进客户机。
  func capturesSystemKeys(for vmName: String) -> Bool {
    runtimeSessions?.session(for: vmName)?.capturesSystemKeys ?? false
  }

  func start(vmName: String, profile: RunProfile) {
    guard let runtimeSessions else { return }

    if profile.hasBlockingIssues {
      // 有阻断性问题时不该白跑一趟让 tart 报错。
      actionError = L10n.text("The run profile has conflicts. Fix them before starting.")
      return
    }

    runtimeSessions.start(vmName: vmName, profile: profile)

    // tart run 要过一会儿才会把状态写进虚拟机目录，延迟刷新一次。
    Task {
      try? await Task.sleep(for: .seconds(2))
      await refresh()
    }
  }

  func stop(vmName: String) async {
    guard let runtimeSessions else { return }
    do {
      try await runtimeSessions.stop(vmName: vmName)
      await refresh()
    } catch {
      actionError = error.localizedDescription
    }
  }

  func suspend(vmName: String) async {
    guard let runtimeSessions else { return }
    do {
      try await runtimeSessions.suspend(vmName: vmName)
      await refresh()
    } catch {
      // 未以 --suspendable 启动的虚拟机会走到这里，tart 的报错已经说清了原因。
      actionError = error.localizedDescription
    }
  }

  /// TartUI 是否掌握着这台虚拟机的进程。
  ///
  /// 用户可能在终端里直接 `tart run`，那样的虚拟机同样显示为运行中，
  /// 但 TartUI 拿不到它的进程句柄，只能请求关机、不能强制结束。
  func isManagedByApp(_ vmName: String) -> Bool {
    runtimeSessions?.isManaged(vmName) ?? false
  }

  func showWindow(vmName: String) {
    guard runtimeSessions?.showWindow(vmName: vmName) == true else {
      actionError = L10n.text("The VM window is not ready yet.")
      return
    }
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
    case .linux: title = L10n.format("Create Linux VM \"%@\"", name)
    case .macOSFromIPSW: title = L10n.format("Create macOS VM \"%@\"", name)
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
      title: L10n.format("Clone \"%@\" → \"%@\"", source, newName),
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
      title: L10n.format("Pull \"%@\"", reference),
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

    let target = remoteNames.count == 1
      ? remoteNames[0]
      : L10n.format("%@ targets", String(remoteNames.count))
    operations.run(
      title: L10n.format("Push \"%@\" → %@", localName, target),
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
    guard let client else { return L10n.text("tart is unavailable.") }
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
    guard let client else { return L10n.text("tart is unavailable.") }
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
      title: L10n.format("Export \"%@\"", name),
      stream: { client.export(name: name, to: path) }
    )
  }

  func importVM(from path: String, name: String) {
    guard let client else { return }

    operations.run(
      title: L10n.format("Import \"%@\"", name),
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
