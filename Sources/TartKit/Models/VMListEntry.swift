import Foundation

/// `tart list --format json` 的一行。
///
/// 字段名大写是 tart 的 JSON schema 决定的（见 tart 的 `Commands/List.swift`），
/// 这里用 CodingKeys 映射成 Swift 惯例的小驼峰。
public struct VMListEntry: Codable, Sendable, Identifiable, Hashable {
  public let source: VMSource
  public let name: String
  /// 磁盘镜像的标称容量（GB）。
  public let diskSizeGB: Int
  /// 实际占用的空间（GB）。稀疏文件下远小于标称容量。
  public let allocatedSizeGB: Int
  public let accessedAt: Date
  public let state: VMState

  /// tart 已把这个字段标为过时（仅为向后兼容保留在 JSON 里），
  /// 判定运行中一律以 `state` 为准。
  private let running: Bool

  /// 列表内的稳定标识。
  ///
  /// 单用 name 不够：本地 VM 和 OCI 镜像可能重名，合并成一个列表后会撞 ID。
  public var id: String { "\(source.rawValue):\(name)" }

  public var isRunning: Bool { state == .running }

  enum CodingKeys: String, CodingKey {
    case source = "Source"
    case name = "Name"
    case diskSizeGB = "Disk"
    case allocatedSizeGB = "Size"
    case accessedAt = "Accessed"
    case state = "State"
    case running = "Running"
  }

  public init(
    source: VMSource,
    name: String,
    diskSizeGB: Int,
    allocatedSizeGB: Int,
    accessedAt: Date,
    state: VMState
  ) {
    self.source = source
    self.name = name
    self.diskSizeGB = diskSizeGB
    self.allocatedSizeGB = allocatedSizeGB
    self.accessedAt = accessedAt
    self.state = state
    self.running = state == .running
  }
}
