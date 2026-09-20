import CryptoKit
import Foundation
import TartKit

/// Installs official Tart release artifacts into TartUI's Application Support
/// directory. TartUI never compiles, patches or embeds Tart source code.
struct TartRuntimeInstaller {
  private static let releaseAPI = URL(string: "https://api.github.com/repos/openai/tart/releases/latest")!
  private static let fallbackArchive = URL(string: "https://github.com/openai/tart/releases/latest/download/tart.tar.gz")!

  private let fileManager: FileManager
  private let applicationSupportURL: URL

  init(
    fileManager: FileManager = .default,
    applicationSupportURL: URL? = nil
  ) {
    self.fileManager = fileManager
    self.applicationSupportURL = applicationSupportURL
      ?? TartLocator.defaultApplicationSupportURL(fileManager: fileManager)
  }

  func latestVersion() async throws -> String {
    try await fetchLatestRelease().version
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

    let signedRoot = tartAppRoot(containing: extractedBinary) ?? extractedBinary
    try await verifyCodeSignature(at: signedRoot)

    return try install(extractedBinary: extractedBinary, version: release.version)
  }

  /// All managed versions retained on disk, newest first.
  func installedVersions() -> [String] {
    let root = versionsRoot
    guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else {
      return []
    }

    return names
      .filter { !$0.hasPrefix(".") }
      .filter { fileManager.fileExists(atPath: root.appendingPathComponent($0).path) }
      .sorted { Self.compareVersions($0, $1) == .orderedDescending }
  }

  /// Switches the managed runtime without downloading anything.
  func activateManagedVersion(_ version: String) throws -> TartRuntime {
    let versionRoot = versionsRoot.appendingPathComponent(version, isDirectory: true)
    let binaryURL = try managedBinary(in: versionRoot)
    try updateCurrentSymlink(to: versionRoot)
    return TartRuntime(binaryURL: binaryURL, source: .managed)
  }

  static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
    compareVersions(candidate, current) == .orderedDescending
  }

  static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let left = versionComponents(lhs)
    let right = versionComponents(rhs)
    let count = max(left.count, right.count)

    for index in 0..<count {
      let a = index < left.count ? left[index] : 0
      let b = index < right.count ? right[index] : 0
      if a < b { return .orderedAscending }
      if a > b { return .orderedDescending }
    }
    return .orderedSame
  }

  private static func versionComponents(_ value: String) -> [Int] {
    value
      .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
      .split(separator: ".")
      .map { part in
        let digits = part.prefix { $0.isNumber }
        return Int(digits) ?? 0
      }
  }

  private var supportRoot: URL {
    applicationSupportURL
      .appendingPathComponent(TartLocator.managedRuntimeDirectoryName, isDirectory: true)
  }

  private var versionsRoot: URL {
    supportRoot.appendingPathComponent("versions", isDirectory: true)
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

  private func install(extractedBinary: URL, version: String) throws -> TartRuntime {
    try fileManager.createDirectory(at: versionsRoot, withIntermediateDirectories: true)

    let safeVersion = version.replacingOccurrences(of: "/", with: "-")
    let versionRoot = versionsRoot.appendingPathComponent(safeVersion, isDirectory: true)

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

    let binaryURL = try managedBinary(in: versionRoot)
    try updateCurrentSymlink(to: versionRoot)
    return TartRuntime(binaryURL: binaryURL, source: .managed)
  }

  private func managedBinary(in versionRoot: URL) throws -> URL {
    let appBinary = versionRoot.appendingPathComponent("tart.app/Contents/MacOS/tart")
    if fileManager.isExecutableFile(atPath: appBinary.path) {
      return appBinary
    }

    let bareBinary = versionRoot.appendingPathComponent("tart")
    if fileManager.isExecutableFile(atPath: bareBinary.path) {
      return bareBinary
    }

    throw TartRuntimeInstallError.binaryMissing
  }

  private func updateCurrentSymlink(to versionRoot: URL) throws {
    try fileManager.createDirectory(at: supportRoot, withIntermediateDirectories: true)

    let currentURL = supportRoot.appendingPathComponent("current", isDirectory: true)
    let nextURL = supportRoot.appendingPathComponent(".current-\(UUID().uuidString)")

    try fileManager.createSymbolicLink(at: nextURL, withDestinationURL: versionRoot)
    if fileManager.fileExists(atPath: currentURL.path) {
      try fileManager.removeItem(at: currentURL)
    }
    try fileManager.moveItem(at: nextURL, to: currentURL)
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
