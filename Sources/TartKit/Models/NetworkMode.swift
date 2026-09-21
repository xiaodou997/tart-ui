import Foundation

/// A VM network mode exposed by Tart.
///
/// Bridged networking accepts multiple host interfaces because Tart's
/// `--net-bridged` option is repeatable. The custom Codable implementation
/// keeps profiles written by older TartUI releases (`interface: String`)
/// compatible with the 2.0 representation (`interfaces: [String]`).
public enum NetworkMode: Sendable, Hashable {
  /// Default shared (NAT) networking. Emits no network argument.
  case shared

  /// Bridge the VM to one or more host network interfaces.
  case bridged(interfaces: [String])

  /// Softnet software networking, with optional isolation rules.
  case softnet(SoftnetOptions)

  /// Host-only networking.
  case hostOnly

  public static var `default`: NetworkMode { .shared }
}

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

  private enum AssociatedKey: String, CodingKey {
    case value = "_0"
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

    if container.contains(.softnet) {
      let nested = try container.nestedContainer(keyedBy: AssociatedKey.self, forKey: .softnet)
      self = .softnet(try nested.decode(SoftnetOptions.self, forKey: .value))
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
      _ = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: .shared)

    case let .bridged(interfaces):
      var nested = container.nestedContainer(keyedBy: BridgedKey.self, forKey: .bridged)

      // Keep the single-adapter representation readable by pre-2.0 TartUI.
      if interfaces.count == 1, let interface = interfaces.first {
        try nested.encode(interface, forKey: .interface)
      } else {
        try nested.encode(interfaces, forKey: .interfaces)
      }

    case let .softnet(options):
      var nested = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: .softnet)
      try nested.encode(options, forKey: .value)

    case .hostOnly:
      _ = container.nestedContainer(keyedBy: AssociatedKey.self, forKey: .hostOnly)
    }
  }
}

/// Softnet mode options.
public struct SoftnetOptions: Codable, Sendable, Hashable {
  /// CIDRs the VM may access, for example `192.168.0.0/24`.
  public var allowedCIDRs: [String]
  /// CIDRs the VM must not access. Block wins on an equal prefix.
  public var blockedCIDRs: [String]
  /// TCP port-forwarding rules.
  public var exposedPorts: [PortForward]

  public init(
    allowedCIDRs: [String] = [],
    blockedCIDRs: [String] = [],
    exposedPorts: [PortForward] = []
  ) {
    self.allowedCIDRs = allowedCIDRs
    self.blockedCIDRs = blockedCIDRs
    self.exposedPorts = exposedPorts
  }
}

/// One TCP forwarding rule: host port -> guest port.
public struct PortForward: Codable, Sendable, Hashable, Identifiable {
  public var id = UUID()
  public var hostPort: Int
  public var guestPort: Int

  public init(hostPort: Int, guestPort: Int) {
    self.hostPort = hostPort
    self.guestPort = guestPort
  }

  public var argumentValue: String { "\(hostPort):\(guestPort)" }

  enum CodingKeys: String, CodingKey {
    case id, hostPort, guestPort
  }
}
