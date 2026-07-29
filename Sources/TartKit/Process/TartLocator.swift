import Foundation

/// 负责在磁盘上找到 tart 可执行文件。
///
/// 从 Finder 启动的 .app 继承的是 launchd 的最小 PATH（通常只有 /usr/bin:/bin:/usr/sbin:/sbin），
/// 拿不到 Homebrew 的目录。所以不能依赖 `which tart`，必须显式探测。
public struct TartLocator: Sendable {
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

  public init(
    searchPaths: [String] = TartLocator.defaultSearchPaths,
    pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
    fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    isExecutableFile: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
  ) {
    self.searchPaths = searchPaths
    self.pathEnvironment = pathEnvironment
    self.fileExists = fileExists
    self.isExecutableFile = isExecutableFile
  }

  /// 用户在设置里手动指定的路径，优先级高于一切自动探测。
  public static let userOverrideDefaultsKey = "TartProBinaryPath"

  /// 解析出可用的 tart 路径。
  ///
  /// 顺序：用户手动指定 → 已知安装位置 → 继承到的 PATH。
  public func locate(userOverride: String? = nil) throws -> URL {
    if let userOverride, !userOverride.isEmpty {
      // 用户明确指了路径，就不要再悄悄回退到别处——那样只会让排查变得困难。
      return try validate(path: userOverride)
    }

    var searched: [String] = []

    for path in searchPaths {
      searched.append(path)
      if isExecutable(at: path) {
        return URL(fileURLWithPath: path)
      }
    }

    for path in pathsFromEnvironment() {
      searched.append(path)
      if isExecutable(at: path) {
        return URL(fileURLWithPath: path)
      }
    }

    throw TartError.binaryNotFound(searchedPaths: searched)
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
