import Foundation

/// Run Profile 的持久化。
///
/// 所有 profile 存在单个 JSON 文件里，而不是每台虚拟机一个文件：
/// 虚拟机名可以包含斜杠（OCI 引用形如 `ghcr.io/cirruslabs/macos-sequoia-base:latest`），
/// 拆成文件名就得处理转义和碰撞，不划算。虚拟机数量也不会大到需要分片。
public struct RunProfileStore: Sendable {
  /// 存储文件的位置。
  public let fileURL: URL
  private let legacyFileURL: URL?

  /// 默认位置：`~/Library/Application Support/TartUI/run-profiles.json`
  public static func defaultFileURL() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return base
      .appendingPathComponent("TartUI", isDirectory: true)
      .appendingPathComponent("run-profiles.json")
  }

  /// 旧版本位置，仅用于改名后的数据迁移。
  private static func legacyDefaultFileURL() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    return base
      .appendingPathComponent("TartPro", isDirectory: true)
      .appendingPathComponent("run-profiles.json")
  }

  public init(fileURL: URL) {
    self.fileURL = fileURL
    self.legacyFileURL = nil
  }

  public init() throws {
    self.fileURL = try Self.defaultFileURL()
    self.legacyFileURL = try? Self.legacyDefaultFileURL()
  }

  // MARK: - 读写

  /// 读取全部 profile。文件不存在时返回空集合，不算错误。
  public func load() throws -> ProfileCollection {
    let sourceURL: URL
    if FileManager.default.fileExists(atPath: fileURL.path) {
      sourceURL = fileURL
    } else if let legacyFileURL,
              FileManager.default.fileExists(atPath: legacyFileURL.path) {
      sourceURL = legacyFileURL
    } else {
      return ProfileCollection()
    }
    let data = try Data(contentsOf: sourceURL)
    // 空文件按空集合处理，避免上一次写入被打断后彻底读不出来。
    guard !data.isEmpty else { return ProfileCollection() }
    return try JSONDecoder().decode(ProfileCollection.self, from: data)
  }

  public func save(_ collection: ProfileCollection) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(collection)

    // 原子写入：中途崩溃不会留下半个文件。
    try data.write(to: fileURL, options: .atomic)
  }
}

/// 全部虚拟机的 profile 集合。
public struct ProfileCollection: Codable, Sendable, Hashable {
  /// 格式版本，为将来的迁移留出余地。
  public private(set) var version: Int
  /// 虚拟机名 → 该机的 profile 列表。
  public private(set) var profilesByVM: [String: [RunProfile]]

  public init(profilesByVM: [String: [RunProfile]] = [:]) {
    self.version = 1
    self.profilesByVM = profilesByVM
  }

  // MARK: - 查询

  public func profiles(for vmName: String) -> [RunProfile] {
    profilesByVM[vmName] ?? []
  }

  /// 取指定虚拟机的某个 profile；没有就返回一份默认配置。
  ///
  /// 让「从没配置过」和「配置过」在调用方看来是一样的，省掉各处的空值判断。
  public func profile(for vmName: String, id: UUID?) -> RunProfile {
    let existing = profiles(for: vmName)
    if let id, let match = existing.first(where: { $0.id == id }) {
      return match
    }
    return existing.first ?? RunProfile()
  }

  // MARK: - 修改

  public mutating func upsert(_ profile: RunProfile, for vmName: String) {
    var list = profilesByVM[vmName] ?? []
    if let index = list.firstIndex(where: { $0.id == profile.id }) {
      list[index] = profile
    } else {
      list.append(profile)
    }
    profilesByVM[vmName] = list
  }

  public mutating func remove(profileID: UUID, for vmName: String) {
    guard var list = profilesByVM[vmName] else { return }
    list.removeAll { $0.id == profileID }
    if list.isEmpty {
      profilesByVM.removeValue(forKey: vmName)
    } else {
      profilesByVM[vmName] = list
    }
  }

  /// 虚拟机改名时同步搬迁它的 profile。
  ///
  /// 不做这一步的话，改名后用户精心配的启动参数就凭空消失了。
  public mutating func rename(vmName: String, to newName: String) {
    guard let list = profilesByVM.removeValue(forKey: vmName) else { return }
    profilesByVM[newName] = list
  }

  /// 虚拟机被删除时清掉它的 profile，避免残留数据无限累积。
  public mutating func removeAll(for vmName: String) {
    profilesByVM.removeValue(forKey: vmName)
  }

  /// 清理掉已经不存在的虚拟机的 profile。
  ///
  /// 用户可能在命令行里直接 `tart delete`，绕过了界面，所以需要这个兜底。
  public mutating func prune(keepingOnly existingVMNames: Set<String>) {
    for name in profilesByVM.keys where !existingVMNames.contains(name) {
      profilesByVM.removeValue(forKey: name)
    }
  }
}
