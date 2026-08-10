import CryptoKit
import Foundation
import TartKit

/// 负责把官方 Tart release 安装到 TartUI 自己管理的运行时目录。
///
/// 正式发布的 App 会把 Tart 直接放进自己的 bundle；这个安装器主要服务于：
/// - 开发包或损坏的 bundle；
/// - 用户主动更新 Tart 运行时；
/// - 以后需要回滚到旧版本的场景。
///
/// 安装过程不会写入 Homebrew，也不会修改用户的 shell 配置。
struct TartRuntimeInstaller {
  private static let releaseAPI = URL(string: "https://api.github.com/repos/openai/tart/releases/latest")!
  private static let fallbackArchive = URL(string: "https://github.com/openai/tart/releases/latest/download/tart.tar.gz")!

  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  func installLatest() async throws -> TartRuntime {
    let release = try await fetchLatestRelease()
    let archiveData = try await download(release.archiveURL)

    if let checksumURL = release.checksumURL {
      let checksumData = try await download(checksumURL)
      try verifyChecksum(
        archiveData: archiveData,
        archiveName: release.archiveName,
        checksumData: checksumData
      )
    }

    let temporaryRoot = fileManager.temporaryDirectory
      .appendingPathComponent("TartUI-runtime-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: temporaryRoot) }

    let archiveURL = temporaryRoot.appendingPathComponent(release.archiveName)
    try archiveData.write(to: archiveURL, options: .atomic)

    let extractedRoot = temporaryRoot.appendingPathComponent("extracted", isDirectory: true)
    try fileManager.createDirectory(at: extractedRoot, withIntermediateDirectories: true)
    try await extract(archiveURL: archiveURL, destination: extractedRoot)

    guard let extractedBinary = findTartBinary(in: extractedRoot) else {
      throw TartRuntimeInstallError.binaryMissing
    }

    // 官方 archive 通常包含 tart.app。优先验证整个 app；如果上游改成裸二进制，
    // 则验证该二进制本身。没有有效签名就不写入可执行运行时目录。
    let signedRoot = tartAppRoot(containing: extractedBinary) ?? extractedBinary
    try await verifyCodeSignature(at: signedRoot)

    return try install(
      extractedBinary: extractedBinary,
      version: release.version,
      temporaryRoot: temporaryRoot
    )
  }

  private func fetchLatestRelease() async throws -> ReleaseInfo {
    var request = URLRequest(url: Self.releaseAPI)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("TartUI/1.0", forHTTPHeaderField: "User-Agent")

    let data = try await requestData(request)
    let release: GitHubRelease
    do {
      release = try JSONDecoder().decode(GitHubRelease.self, from: data)
    } catch {
      throw TartRuntimeInstallError.invalidReleaseMetadata(error.localizedDescription)
    }

    let archive = release.assets.first { asset in
      asset.name == "tart.tar.gz"
    } ?? release.assets.first { asset in
      asset.name.hasSuffix(".tar.gz") &&
        asset.name.lowercased().contains("darwin")
    } ?? release.assets.first { asset in
      asset.name.hasSuffix(".tar.gz")
    }

    let archiveURL = archive?.browserDownloadURL ?? Self.fallbackArchive
    let archiveName = archive?.name ?? "tart.tar.gz"
    let checksum = release.assets.first { asset in
      let name = asset.name.lowercased()
      return name.contains("checksums") || name.contains("sha256")
    }

    return ReleaseInfo(
      version: release.tagName,
      archiveURL: archiveURL,
      archiveName: archiveName,
      checksumURL: checksum?.browserDownloadURL
    )
  }

  private func download(_ url: URL) async throws -> Data {
    var request = URLRequest(url: url)
    request.setValue("TartUI/1.0", forHTTPHeaderField: "User-Agent")
    return try await requestData(request)
  }

  private func requestData(_ request: URLRequest) async throws -> Data {
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode)
      else {
        throw TartRuntimeInstallError.downloadFailed(request.url?.absoluteString ?? "unknown URL")
      }
      return data
    } catch let error as TartRuntimeInstallError {
      throw error
    } catch {
      throw TartRuntimeInstallError.downloadFailed(error.localizedDescription)
    }
  }

  private func verifyChecksum(
    archiveData: Data,
    archiveName: String,
    checksumData: Data
  ) throws {
    let expected = checksumData
      .split(whereSeparator: { $0 == 10 || $0 == 13 })
      .compactMap { line -> String? in
        let text = String(decoding: line, as: UTF8.self)
        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2 else { return nil }
        let name = String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
        return name == archiveName ? String(fields[0]) : nil
      }
      .first

    guard let expected else {
      // 上游没有为当前 archive 提供对应校验项时，后面的代码签名校验仍然有效。
      return
    }

    let actual = SHA256.hash(data: archiveData)
      .map { String(format: "%02x", $0) }
      .joined()
    guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
      throw TartRuntimeInstallError.checksumMismatch
    }
  }

  private func extract(archiveURL: URL, destination: URL) async throws {
    try await Task.detached(priority: .utility) {
      try Self.runProcess(
        executable: URL(fileURLWithPath: "/usr/bin/tar"),
        arguments: ["-xzf", archiveURL.path, "-C", destination.path]
      )
    }.value
  }

  private func verifyCodeSignature(at url: URL) async throws {
    try await Task.detached(priority: .utility) {
      try Self.runProcess(
        executable: URL(fileURLWithPath: "/usr/bin/codesign"),
        arguments: ["--verify", "--strict", url.path]
      )
    }.value
  }

  private func findTartBinary(in root: URL) -> URL? {
    let preferred = root.appendingPathComponent("tart.app/Contents/MacOS/tart")
    if fileManager.isExecutableFile(atPath: preferred.path) {
      return preferred
    }

    guard let enumerator = fileManager.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
      options: [.skipsHiddenFiles]
    ) else {
      return nil
    }

    for case let url as URL in enumerator where url.lastPathComponent == "tart" {
      if fileManager.isExecutableFile(atPath: url.path) {
        return url
      }
    }
    return nil
  }

  private func tartAppRoot(containing binary: URL) -> URL? {
    var current = binary.deletingLastPathComponent()
    while current.path != current.deletingLastPathComponent().path {
      if current.lastPathComponent == "tart.app" {
        return current
      }
      current = current.deletingLastPathComponent()
    }
    return nil
  }

  private func install(
    extractedBinary: URL,
    version: String,
    temporaryRoot: URL
  ) throws -> TartRuntime {
    let supportRoot = TartLocator.defaultApplicationSupportURL()
      .appendingPathComponent(TartLocator.managedRuntimeDirectoryName, isDirectory: true)
    let versionsRoot = supportRoot.appendingPathComponent("versions", isDirectory: true)
    try fileManager.createDirectory(at: versionsRoot, withIntermediateDirectories: true)

    let safeVersion = version.replacingOccurrences(of: "/", with: "-")
    let versionRoot = versionsRoot.appendingPathComponent(safeVersion, isDirectory: true)
    let binaryURL: URL

    if !fileManager.fileExists(atPath: versionRoot.path) {
      let stagingRoot = supportRoot
        .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
      try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
      defer { try? fileManager.removeItem(at: stagingRoot) }

      if let appRoot = tartAppRoot(containing: extractedBinary) {
        try fileManager.copyItem(
          at: appRoot,
          to: stagingRoot.appendingPathComponent("tart.app", isDirectory: true)
        )
      } else {
        let destination = stagingRoot.appendingPathComponent("tart", isDirectory: false)
        try fileManager.copyItem(at: extractedBinary, to: destination)
      }
      try fileManager.moveItem(at: stagingRoot, to: versionRoot)
    }

    let appBinary = versionRoot.appendingPathComponent("tart.app/Contents/MacOS/tart")
    if fileManager.isExecutableFile(atPath: appBinary.path) {
      binaryURL = appBinary
    } else {
      binaryURL = versionRoot.appendingPathComponent("tart")
    }

    guard fileManager.isExecutableFile(atPath: binaryURL.path) else {
      throw TartRuntimeInstallError.binaryMissing
    }

    let currentURL = supportRoot.appendingPathComponent("current", isDirectory: true)
    let nextURL = supportRoot.appendingPathComponent(".current-\(UUID().uuidString)")
    try fileManager.createSymbolicLink(at: nextURL, withDestinationURL: versionRoot)
    if fileManager.fileExists(atPath: currentURL.path) {
      try fileManager.removeItem(at: currentURL)
    }
    try fileManager.moveItem(at: nextURL, to: currentURL)

    _ = temporaryRoot // Keep the extraction lifetime tied to the caller's defer.
    return TartRuntime(binaryURL: binaryURL, source: .managed)
  }

  private static func runProcess(executable: URL, arguments: [String]) throws {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let stderr = Pipe()
    process.standardError = stderr

    do {
      try process.run()
    } catch {
      throw TartRuntimeInstallError.toolFailed(executable.lastPathComponent, error.localizedDescription)
    }
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
      let output = stderr.fileHandleForReading.readDataToEndOfFile()
      let detail = String(decoding: output, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      throw TartRuntimeInstallError.toolFailed(
        executable.lastPathComponent,
        detail.isEmpty ? "exit code \(process.terminationStatus)" : detail
      )
    }
  }
}

private struct ReleaseInfo: Sendable {
  let version: String
  let archiveURL: URL
  let archiveName: String
  let checksumURL: URL?
}

private struct GitHubRelease: Decodable, Sendable {
  let tagName: String
  let assets: [GitHubAsset]

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case assets
  }
}

private struct GitHubAsset: Decodable, Sendable {
  let name: String
  let browserDownloadURL: URL

  enum CodingKeys: String, CodingKey {
    case name
    case browserDownloadURL = "browser_download_url"
  }
}

enum TartRuntimeInstallError: Error, LocalizedError, Sendable {
  case downloadFailed(String)
  case invalidReleaseMetadata(String)
  case checksumMismatch
  case binaryMissing
  case toolFailed(String, String)

  var errorDescription: String? {
    switch self {
    case let .downloadFailed(detail):
      return "Could not download the Tart runtime: \(detail)"
    case let .invalidReleaseMetadata(detail):
      return "Could not read the latest Tart release: \(detail)"
    case .checksumMismatch:
      return "The downloaded Tart archive failed its checksum verification."
    case .binaryMissing:
      return "The Tart release did not contain an executable tart binary."
    case let .toolFailed(tool, detail):
      return "\(tool) failed: \(detail)"
    }
  }
}
