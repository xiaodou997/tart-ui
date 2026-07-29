import Foundation

/// 虚拟机状态。对应 tart `VMDirectory.State`。
public enum VMState: String, Codable, Sendable, CaseIterable {
  case running
  case suspended
  case stopped

  /// 未知状态的兜底。
  ///
  /// 上游若新增状态值，这里要保证只是显示成「未知」而不是整条列表解码失败。
  case unknown

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = VMState(rawValue: raw) ?? .unknown
  }
}

/// VM 的来源：本地创建的，还是从 OCI registry 拉下来的缓存。
public enum VMSource: String, Codable, Sendable {
  case local
  case oci = "OCI"
  case unknown

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    self = VMSource(rawValue: raw) ?? .unknown
  }

  /// OCI 来源的条目是只读缓存，不能改配置、不能重命名。
  public var isMutable: Bool { self == .local }
}
