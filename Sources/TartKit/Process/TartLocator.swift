import Foundation

/// Tart 的来源。来源信息会显示在设置页和诊断信息中，方便区分内置运行时与系统安装。
public enum TartRuntimeSource: String, Sendable, Equatable {
  case bundled
  case managed
  case userOverride
  case system
}

/// 已解析的 Tart 运行时。
public struct TartRuntime: Sendable, Equatable {
  public let binaryURL: URL
  public let source: TartRuntimeSource

  public init(binaryURL: URL, source: TartRuntimeSource) {
    self.binaryURL = binaryURL
    self.source = source
  }
}

/// 负责在磁盘上找到 tart 可执行文件。
///
/// 从 Finder 启动的 .app 继承的是 launchd 的最小 PATH（通常只有 /usr/bin:/bin:/usr/sbin:/sbin），
/// 拿不到 Homebrew 的目录。所以不能依赖 `which tart`，必须显式探测。
public struct TartLocator: Sendable {
  public static let managedRuntimeDirectoryName = "TartUI/Runtimes"

  /// 按优先级排列的候选路径。Apple Silicon 上 Homebrew 装在 /opt/homebrew。
  public static let defaultSearchPaths = [
    "/opt/homebrew/bin/tart",
    "/usr/local/bin/tart",
  ]

  private let searchPaths: [String]
  /// 判断给定路径是否是一个可执行文件。
  ///
  /// 抽成闭包而不是直接持有 `FileManager`：后者不是 `Sendable`，
  /// 而且注入闭包让「路径存在但不可执行」这类分支在测试里可以直接构造。
  private let isExecutableFile: @Sendable (String) -> Bool
  private let fileExists: @Sendable (String) -> Bool
  /// 进程继承到的 PATH。显式注入而非直接读全局环境，否则这个类型不可测。
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
    // 只用真实 FileManager 过滤默认候选，避免测试注入的「所有路径都存在」闭包
    // 把 XCTest bundle 或不存在的 Application Support 路径误判为运行时。
    self.bundledPaths = bundledPaths ?? Self.defaultBundledSearchPaths()
      .filter { FileManager.default.isExecutableFile(atPath: $0) }
    self.managedPaths = managedPaths ?? Self.defaultManagedSearchPaths()
      .filter { FileManager.default.isExecutableFile(atPath: $0) }
  }

  /// 用户在设置里手动指定的路径，优先级高于一切自动探测。
  public static let userOverrideDefaultsKey = "TartUIBinaryPath"
  /// 旧版本的设置键。改名后读取并迁移，避免用户重新选择 tart 路径。
  public static let legacyUserOverrideDefaultsKey = "TartProBinaryPath"

  /// 读取用户指定的 tart 路径，并在首次读取时迁移旧版键名。
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

  /// 解析出可用的 Tart 运行时及其来源。
  ///
  /// 顺序：用户手动指定 → App 内置 → TartUI 托管版本 → 系统安装位置 → PATH。
  public func resolve(userOverride: String? = nil) throws -> TartRuntime {
    if let userOverride, !userOverride.isEmpty {
      // 用户明确指了路径，就不要再悄悄回退到别处——那样只会让排查变得困难。
      return TartRuntime(binaryURL: try validate(path: userOverride), source: .userOverride)
    }

    var searched: [String] = []

    for path in bundledPaths {
      searched.append(path)
      if isExecutable(at: path) {
        return TartRuntime(binaryURL: URL(fileURLWithPath: path), source: .bundled)
      }
    }

    for path in managedPaths {
      searched.append(path)
      if isExecutable(at: path) {
        return TartRuntime(binaryURL: URL(fileURLWithPath: path), source: .managed)
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

    throw TartError.binaryNotFound(searchedPaths: searched)
  }

  /// 兼容原有调用方，只返回可执行文件路径。
  public func locate(userOverride: String? = nil) throws -> URL {
    try resolve(userOverride: userOverride).binaryURL
  }

  /// App 包内的 Tart helper 候选路径。
  ///
  /// release App 使用隐藏的 `Contents/Helpers/tart.app`；保留其它形式是为了
  /// 支持 SwiftPM 开发运行和旧的本地打包产物。
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

  /// TartUI 托管的版本化运行时候选路径。
  ///
  /// `current` 是运行时管理器维护的稳定入口，实际版本目录可以随时切换和回滚。
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

  /// 校验一个明确给出的路径确实可用。
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

  /// 从当前进程继承到的 PATH 里凑候选项。
  ///
  /// 从终端 `swift run` 启动时这一步能命中；从 Finder 启动时基本是空手而归，
  /// 属于兜底而非主力。
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
