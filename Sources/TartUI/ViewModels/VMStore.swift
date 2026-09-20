import Foundation
import Observation
import TartKit

/// Application state and the boundary between SwiftUI and the official tart CLI.
@Observable
@MainActor
final class VMStore {
  private(set) var entries: [VMListEntry] = []
  private(set) var isLoading = false
  private(set) var loadError: String?

  /// Nil when no usable tart executable has been found.
  private(set) var client: TartClient?
  private(set) var runtime: TartRuntime?
  private(set) var tartVersion: String?
  private(set) var isInstallingRuntime = false
  private(set) var runtimeInstallError: String?
  private(set) var latestOfficialTartVersion: String?
  private(set) var isCheckingRuntimeUpdate = false
  private(set) var runtimeUpdateError: String?
  private(set) var managedVersions: [String] = []

  var runtimeSource: TartRuntimeSource? { runtime?.source }

  var isRuntimeUpdateAvailable: Bool {
    guard let current = tartVersion, let latest = latestOfficialTartVersion else { return false }
    return TartRuntimeInstaller.isVersion(latest, newerThan: current)
  }

  var previousManagedVersion: String? {
    guard runtime?.source == .managed, let current = tartVersion else { return nil }
    return managedVersions.first {
      TartRuntimeInstaller.compareVersions($0, current) == .orderedAscending
    }
  }

  /// Unified history for user-triggered Tart CLI actions.
  let operations = OperationCenter()

  private(set) var profiles = ProfileCollection()
  private var profileStore: RunProfileStore?

  var actionError: String?

  private var pollingTask: Task<Void, Never>?
  private let pollInterval: Duration = .seconds(3)

  // MARK: - Bootstrap

  func bootstrap(userOverride: String? = nil) async {
    do {
      let runtime = try TartLocator().resolve(userOverride: userOverride)
      let client = TartClient(runtime: runtime)
      let version = try await client.version()
      await activate(runtime: runtime, client: client, version: version)
    } catch {
      stopAutoSync()
      self.client = nil
      self.runtime = nil
      self.tartVersion = nil
      self.managedVersions = TartRuntimeInstaller().installedVersions()
      self.loadError = error.localizedDescription
    }
  }

  /// Validates a runtime choice before persisting it. Invalid paths never become
  /// the next-launch default.
  func applyRuntimePath(_ path: String?) async -> String? {
    let normalized = path?.trimmingCharacters(in: .whitespacesAndNewlines)
    let override = normalized?.isEmpty == false ? normalized : nil

    do {
      let runtime = try TartLocator().resolve(userOverride: override)
      let client = TartClient(runtime: runtime)
      let version = try await client.version()

      let defaults = UserDefaults.standard
      if let override {
        defaults.set(override, forKey: TartLocator.userOverrideDefaultsKey)
      } else {
        defaults.removeObject(forKey: TartLocator.userOverrideDefaultsKey)
        defaults.removeObject(forKey: TartLocator.legacyUserOverrideDefaultsKey)
      }

      await activate(runtime: runtime, client: client, version: version)
      return nil
    } catch {
      if client == nil {
        loadError = error.localizedDescription
      }
      return error.localizedDescription
    }
  }

  /// Downloads and activates the latest official Tart release as a TartUI-managed runtime.
  func installLatestRuntime() async {
    guard !isInstallingRuntime else { return }

    isInstallingRuntime = true
    runtimeInstallError = nil
    defer { isInstallingRuntime = false }

    do {
      let runtime = try await TartRuntimeInstaller().installLatest()
      let client = TartClient(runtime: runtime)
      let version = try await client.version()

      let defaults = UserDefaults.standard
      defaults.removeObject(forKey: TartLocator.userOverrideDefaultsKey)
      defaults.removeObject(forKey: TartLocator.legacyUserOverrideDefaultsKey)

      await activate(runtime: runtime, client: client, version: version)
      latestOfficialTartVersion = version
    } catch {
      runtimeInstallError = error.localizedDescription
      if client == nil {
        loadError = error.localizedDescription
      }
    }
  }

  func checkForRuntimeUpdate() async {
    guard !isCheckingRuntimeUpdate else { return }

    isCheckingRuntimeUpdate = true
    runtimeUpdateError = nil
    defer { isCheckingRuntimeUpdate = false }

    do {
      latestOfficialTartVersion = try await TartRuntimeInstaller().latestVersion()
    } catch {
      runtimeUpdateError = error.localizedDescription
    }
  }

  func rollbackManagedRuntime(to version: String) async {
    guard runtime?.source == .managed else { return }

    do {
      let runtime = try TartRuntimeInstaller().activateManagedVersion(version)
      let client = TartClient(runtime: runtime)
      let actualVersion = try await client.version()
      await activate(runtime: runtime, client: client, version: actualVersion)
    } catch {
      runtimeUpdateError = error.localizedDescription
    }
  }

  private func activate(runtime: TartRuntime, client: TartClient, version: String) async {
    self.runtime = runtime
    self.client = client
    self.tartVersion = version
    self.loadError = nil
    self.runtimeInstallError = nil
    self.runtimeUpdateError = nil
    self.latestOfficialTartVersion = nil
    self.managedVersions = TartRuntimeInstaller().installedVersions()

    loadProfiles()
    await refresh()
    pruneOrphanProfiles()
    startAutoSync()
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

  // MARK: - Automatic refresh

  /// tart is the source of truth. Poll its JSON list output instead of inspecting
  /// Tart's private on-disk implementation.
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
  }

  func stopAutoSync() {
    pollingTask?.cancel()
    pollingTask = nil
  }

  private func refreshQuietly() async {
    guard let client else { return }
    guard let fresh = try? await client.list() else { return }

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

  // MARK: - Run profiles

  private func loadProfiles() {
    do {
      let store = try RunProfileStore()
      profileStore = store
      profiles = try store.load()
    } catch {
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

  // MARK: - VM lifecycle

  /// Starts the official tart run process. Tart owns the VM and its native window.
  func start(vmName: String, profile: RunProfile) {
    guard let client else { return }

    if profile.hasBlockingIssues {
      actionError = L10n.text("The run profile has conflicts. Fix them before starting.")
      return
    }

    let action = client.runAction(name: vmName, profile: profile)
    operations.run(
      title: L10n.format("Run \"%@\"", vmName),
      action: action,
      stream: { client.stream(action) },
      onSuccess: { [weak self] in await self?.refresh() }
    )

    Task {
      try? await Task.sleep(for: .seconds(2))
      await refresh()
    }
  }

  func stop(vmName: String) async {
    guard let client else { return }
    let action = client.stopAction(name: vmName)

    do {
      _ = try await operations.perform(
        title: "\(L10n.text("Stop")) \(vmName)",
        action: action,
        execute: { try await client.stop(name: vmName) }
      )
      await refresh()
    } catch {
      actionError = error.localizedDescription
    }
  }

  func suspend(vmName: String) async {
    guard let client else { return }
    let action = client.suspendAction(name: vmName)

    do {
      _ = try await operations.perform(
        title: "\(L10n.text("Suspend")) \(vmName)",
        action: action,
        execute: { try await client.suspend(name: vmName) }
      )
      await refresh()
    } catch {
      actionError = error.localizedDescription
    }
  }

  // MARK: - Create and clone

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

    let action = client.createAction(name: name, source: source, diskSizeGB: diskSizeGB, diskFormat: diskFormat)
    operations.run(
      title: title,
      action: action,
      stream: { client.stream(action) },
      onSuccess: { [weak self] in await self?.refresh() }
    )
  }

  func cloneVM(source: String, newName: String, insecure: Bool = false, concurrency: UInt? = nil) {
    guard let client else { return }

    let action = client.cloneAction(source: source, newName: newName, insecure: insecure, concurrency: concurrency)
    operations.run(
      title: L10n.format("Clone \"%@\" → \"%@\"", source, newName),
      action: action,
      stream: { client.stream(action) },
      onSuccess: { [weak self] in await self?.refresh() }
    )
  }

  // MARK: - Modify and delete

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
    let action = client.setAction(
      name: name,
      cpuCount: cpuCount,
      memoryMB: memoryMB,
      display: display,
      displayUnit: displayUnit,
      randomMAC: randomMAC,
      randomSerial: randomSerial,
      diskSizeGB: diskSizeGB
    )

    do {
      _ = try await operations.perform(
        title: "\(L10n.text("Edit Configuration")) \(name)",
        action: action,
        execute: {
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
        }
      )
      await refresh()
    } catch {
      actionError = error.localizedDescription
    }
  }

  func delete(names: [String]) async {
    guard let client else { return }
    let action = client.deleteAction(names: names)
    do {
      _ = try await operations.perform(
        title: L10n.text("Delete"),
        action: action,
        execute: { try await client.delete(names: names) }
      )
      for name in names {
        profiles.removeAll(for: name)
      }
      persistProfiles()
      await refresh()
    } catch {
      actionError = error.localizedDescription
    }
  }

  // MARK: - Registry

  func pull(reference: String, insecure: Bool = false, concurrency: UInt? = nil) {
    guard let client else { return }

    let action = client.pullAction(remoteName: reference, insecure: insecure, concurrency: concurrency)
    operations.run(
      title: L10n.format("Pull \"%@\"", reference),
      action: action,
      stream: { client.stream(action) },
      onSuccess: { [weak self] in await self?.refresh() }
    )
  }

  func login(
    host: String,
    username: String,
    password: String,
    insecure: Bool,
    validate: Bool
  ) async -> String? {
    guard let client else { return L10n.text("tart is unavailable.") }
    let action = client.loginAction(host: host, username: username, insecure: insecure, validate: validate)
    do {
      _ = try await operations.perform(
        title: "\(L10n.text("Log In")) \(host)",
        action: action,
        execute: {
          try await client.login(
            host: host,
            username: username,
            password: password,
            insecure: insecure,
            validate: validate
          )
        }
      )
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  func logout(host: String) async -> String? {
    guard let client else { return L10n.text("tart is unavailable.") }
    let action = client.logoutAction(host: host)
    do {
      _ = try await operations.perform(
        title: "\(L10n.text("Log Out")) \(host)",
        action: action,
        execute: { try await client.logout(host: host) }
      )
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  // MARK: - Import

  func importVM(from path: String, name: String) {
    guard let client else { return }

    let action = client.importAction(from: path, name: name)
    operations.run(
      title: L10n.format("Import \"%@\"", name),
      action: action,
      stream: { client.stream(action) },
      onSuccess: { [weak self] in await self?.refresh() }
    )
  }

  // MARK: - Maintenance

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
    let action = client.pruneAction(target: target, olderThanDays: olderThanDays, spaceBudgetGB: spaceBudgetGB)
    do {
      _ = try await operations.perform(
        title: L10n.text("Prune Disk Space"),
        action: action,
        execute: { try await client.prune(target: target, olderThanDays: olderThanDays, spaceBudgetGB: spaceBudgetGB) }
      )
      await refresh()
      pruneOrphanProfiles()
    } catch {
      actionError = error.localizedDescription
    }
  }

  // MARK: - Guest access

  func ipAddress(for vmName: String, waitSeconds: UInt? = nil) async -> String? {
    guard let client else { return nil }
    let action = client.ipAction(name: vmName, waitSeconds: waitSeconds)

    do {
      let result = try await operations.perform(
        title: "\(L10n.text("IP Address")): \(vmName)",
        action: action,
        execute: { try await client.ipResult(name: vmName, waitSeconds: waitSeconds) }
      )
      return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      return nil
    }
  }

  func pruneOrphanProfiles() {
    let existing = Set(entries.map(\.name))
    guard !existing.isEmpty else { return }
    profiles.prune(keepingOnly: existing)
    persistProfiles()
  }
}
