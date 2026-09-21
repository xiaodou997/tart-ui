import Foundation

/// Network modes currently exposed by TartUI.
public enum NetworkMode: Sendable, Hashable {
  /// Default shared (NAT) networking. Emits no network argument.
  case shared

  /// Bridge the VM to one or more host network interfaces.
  case bridged(interfaces: [String])

  /// Tart's Softnet mode with its default behavior.
  case softnet

  /// Host-only networking.
  case hostOnly

  public static var `default`: NetworkMode { .shared }
}

/// Decode the profile shapes written before Network Settings 2.0 without
/// keeping their removed advanced behavior.
///
/// Older bridged profiles stored one `interface` string. Older Softnet
/// profiles carried allow/block/port-forward options. Both shapes are accepted,
/// then normalized to the current visible model.
extension NetworkMode: Codable {
  private enum CaseKey: String, CodingKey {
    case shared
    case bridged
    case softnet
    case hostOnly
  }

  private enum BridgedKey: String, CodingKey {
    case interface
    case interfaces
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CaseKey.self)

    if container.contains(.shared) {
      self = .shared
      return
    }

    if container.contains(.hostOnly) {
      self = .hostOnly
      return
    }

    if container.contains(.softnet) {
      self = .softnet
      return
    }

    if container.contains(.bridged) {
      let nested = try container.nestedContainer(keyedBy: BridgedKey.self, forKey: .bridged)

      if let interfaces = try nested.decodeIfPresent([String].self, forKey: .interfaces) {
        self = .bridged(interfaces: interfaces)
        return
      }

      if let legacyInterface = try nested.decodeIfPresent(String.self, forKey: .interface) {
        self = .bridged(interfaces: [legacyInterface])
        return
      }

      self = .bridged(interfaces: [])
      return
    }

    throw DecodingError.dataCorrupted(
      DecodingError.Context(
        codingPath: decoder.codingPath,
        debugDescription: "Unknown TartUI network mode."
      )
    )
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CaseKey.self)

    switch self {
    case .shared:
      _ = container.nestedContainer(keyedBy: BridgedKey.self, forKey: .shared)

    case let .bridged(interfaces):
      var nested = container.nestedContainer(keyedBy: BridgedKey.self, forKey: .bridged)
      try nested.encode(interfaces, forKey: .interfaces)

    case .softnet:
      _ = container.nestedContainer(keyedBy: BridgedKey.self, forKey: .softnet)

    case .hostOnly:
      _ = container.nestedContainer(keyedBy: BridgedKey.self, forKey: .hostOnly)
    }
  }
}
