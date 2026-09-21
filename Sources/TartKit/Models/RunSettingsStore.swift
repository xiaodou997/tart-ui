import Foundation

/// Persists one launch-settings value per local VM.
public struct RunSettingsStore: Sendable {
  public let fileURL: URL

  /// Default location: `~/Library/Application Support/TartUI/run-settings.json`.
  public static func defaultFileURL() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )

    return base
      .appendingPathComponent("TartUI", isDirectory: true)
      .appendingPathComponent("run-settings.json")
  }

  public init(fileURL: URL) {
    self.fileURL = fileURL
  }

  public init() throws {
    self.fileURL = try Self.defaultFileURL()
  }

  public func load() throws -> RunSettingsCollection {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return RunSettingsCollection()
    }

    let data = try Data(contentsOf: fileURL)
    guard !data.isEmpty else { return RunSettingsCollection() }
    return try JSONDecoder().decode(RunSettingsCollection.self, from: data)
  }

  public func save(_ collection: RunSettingsCollection) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(collection)
    try data.write(to: fileURL, options: .atomic)
  }
}

/// All per-VM launch settings owned by TartUI.
public struct RunSettingsCollection: Codable, Sendable, Hashable {
  public private(set) var settingsByVM: [String: RunSettings]

  public init(settingsByVM: [String: RunSettings] = [:]) {
    self.settingsByVM = settingsByVM
  }

  /// Returns saved settings, or TartUI's minimal defaults for an unconfigured VM.
  public func settings(for vmName: String) -> RunSettings {
    settingsByVM[vmName] ?? RunSettings()
  }

  public mutating func set(_ settings: RunSettings, for vmName: String) {
    settingsByVM[vmName] = settings
  }

  public mutating func rename(vmName: String, to newName: String) {
    guard let settings = settingsByVM.removeValue(forKey: vmName) else { return }
    settingsByVM[newName] = settings
  }

  public mutating func remove(for vmName: String) {
    settingsByVM.removeValue(forKey: vmName)
  }

  public mutating func prune(keepingOnly existingVMNames: Set<String>) {
    for name in settingsByVM.keys where !existingVMNames.contains(name) {
      settingsByVM.removeValue(forKey: name)
    }
  }
}
