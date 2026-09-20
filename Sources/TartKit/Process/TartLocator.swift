import Foundation

/// Where the tart executable came from.
public enum TartRuntimeSource: String, Sendable, Equatable {
  case managed
  case userOverride
  case system
}

/// A resolved tart executable.
public struct TartRuntime: Sendable, Equatable {
  public let binaryURL: URL
  public let source: TartRuntimeSource

  public init(binaryURL: URL, source: TartRuntimeSource) {
    self.binaryURL = binaryURL
    self.source = source
  }
}

/// Finds a usable official tart executable.
///
/// Finder-launched apps inherit a minimal PATH, so Homebrew locations must be
/// checked explicitly. TartUI never bundles Tart in its own app.
public struct TartLocator: Sendable {
  public static let managedRuntimeDirectoryName = "TartUI/Runtimes"

  public static let defaultSearchPaths = [
    "/opt/homebrew/bin/tart",
    "/usr/local/bin/tart",
  ]

  private let searchPaths: [String]
  private let isExecutableFile: @Sendable (String) -> Bool
  private let fileExists: @Sendable (String) -> Bool
  private let pathEnvironment: String?
  private let managedPaths: [String]

  public init(
    searchPaths: [String] = TartLocator.defaultSearchPaths,
    pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
    fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    isExecutableFile: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
    managedPaths: [String]? = nil
  ) {
    self.searchPaths = searchPaths
    self.pathEnvironment = pathEnvironment
    self.fileExists = fileExists
    self.isExecutableFile = isExecutableFile
    self.managedPaths = managedPaths ?? Self.defaultManagedSearchPaths()
      .filter { FileManager.default.isExecutableFile(atPath: $0) }
  }

  public static let userOverrideDefaultsKey = "TartUIBinaryPath"
  public static let legacyUserOverrideDefaultsKey = "TartProBinaryPath"

  public static func storedUserOverride(defaults: UserDefaults = .standard) -> String? {
    if let current = defaults.string(forKey: userOverrideDefaultsKey), !current.isEmpty {
      return current
    }

    guard let legacy = defaults.string(forKey: legacyUserOverrideDefaultsKey), !legacy.isEmpty else {
      return nil
    }

    defaults.set(legacy, forKey: userOverrideDefaultsKey)
    return legacy
  }

  /// Resolution order:
  /// explicit user path -> known system installs -> PATH -> TartUI-managed fallback.
  public func resolve(userOverride: String? = nil) throws -> TartRuntime {
    if let userOverride, !userOverride.isEmpty {
      return TartRuntime(binaryURL: try validate(path: userOverride), source: .userOverride)
    }

    var searched: [String] = []

    for path in searchPaths {
      searched.append(path)
      if isExecutable(at: path) {
        return TartRuntime(binaryURL: URL(fileURLWithPath: path), source: .system)
      }
    }

    for path in pathsFromEnvironment() {
      searched.append(path)
      if isExecutable(at: path) {
        return TartRuntime(binaryURL: URL(fileURLWithPath: path), source: .system)
      }
    }

    for path in managedPaths {
      searched.append(path)
      if isExecutable(at: path) {
        return TartRuntime(binaryURL: URL(fileURLWithPath: path), source: .managed)
      }
    }

    throw TartError.binaryNotFound(searchedPaths: searched)
  }

  public func locate(userOverride: String? = nil) throws -> URL {
    try resolve(userOverride: userOverride).binaryURL
  }

  public static func defaultManagedSearchPaths(
    applicationSupportURL: URL = TartLocator.defaultApplicationSupportURL()
  ) -> [String] {
    let root = applicationSupportURL
      .appendingPathComponent(managedRuntimeDirectoryName, isDirectory: true)

    let candidates = [
      root.appendingPathComponent("current/tart"),
      root.appendingPathComponent("current/tart.app/Contents/MacOS/tart"),
    ]

    return uniquePaths(candidates.map(\.path))
  }

  public static func defaultApplicationSupportURL(
    fileManager: FileManager = .default
  ) -> URL {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
  }

  private static func uniquePaths(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }

  private func validate(path: String) throws -> URL {
    let expanded = (path as NSString).expandingTildeInPath

    guard fileExists(expanded) else {
      throw TartError.binaryNotFound(searchedPaths: [expanded])
    }
    guard isExecutableFile(expanded) else {
      throw TartError.binaryNotExecutable(path: expanded)
    }

    return URL(fileURLWithPath: expanded)
  }

  private func isExecutable(at path: String) -> Bool {
    isExecutableFile(path)
  }

  private func pathsFromEnvironment() -> [String] {
    guard let rawPath = pathEnvironment else {
      return []
    }

    return rawPath
      .split(separator: ":")
      .map { "\($0)/tart" }
      .filter { !searchPaths.contains($0) }
  }
}
