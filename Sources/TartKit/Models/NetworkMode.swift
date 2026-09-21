import Foundation

/// Network modes currently exposed by TartUI.
public enum NetworkMode: Codable, Sendable, Hashable {
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
