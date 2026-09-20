import Foundation

/// Where the tart executable came from.
public enum TartRuntimeSource: String, Sendable, Equatable {
  // Kept for compatibility with older TartUI builds. New releases do not bundle Tart.
  case bundled
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
/// checked explicitly.
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
  private let bundledPaths: [String]
  private let managedPaths: [String]

  public init(
    searchPaths: [String] = TartLocator.defaultSearchPaths,
    pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
    fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    isExecutableFile: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
    bundledPaths: [String]? = nil,
    managedPaths: [String]? = nil
  ) {
    self.searchPaths = searchPaths
    self.pathEnvironment = pathEnvironment
    self.fileExists = fileExists
    self.isExecutableFile = isExecutableFile

    // Bundled lookup is retained only for backwards compatibility with old local
    // builds. New TartUI releases do not ship a Tart helper.
    self.bundledPaths = bundledPaths ?? Self.defaultBundledSearchPaths()
      .filter { FileManager.default.isExecutableFile(atPath: $0) }

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
  /// explicit user path -> legacy bundled path -> system install -> PATH -> managed fallback.
  public func resolve(userOverride: String? = nil) throws -> TartRuntime {
    if let userOverride, !userOverride.isEmpty {
      return TartRuntime(binaryURL: try validate(path: userOverride), source: .userOverride)
    }

    var searched: [String] = []

    for path in bundledPaths {
      searched.append(path)
      if isExecutable(at: path) {
        return TartRuntime(binaryURL: URL(fileURLWithPath: path), source: .bundled)
      }
    }

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

  /// Compatibility lookup for old locally built app bundles.
  public static func defaultBundledSearchPaths(bundleURL: URL = Bundle.main.bundleURL) -> [String] {
    let candidates = [
      bundleURL.appendingPathComponent("Contents/Helpers/tart.app/Contents/MacOS/tart"),
      bundleURL.appendingPathComponent("Contents/Helpers/tart"),
      bundleURL.appendingPathComponent("Helpers/tart"),
      bundleURL.appendingPathComponent("Contents/Resources/tart"),
      bundleURL.appendingPathComponent("tart"),
    ]
    return uniquePaths(candidates.map(\.path))
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
