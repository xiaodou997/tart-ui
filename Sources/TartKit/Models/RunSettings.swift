import Foundation

/// The single set of common `tart run` options saved for one VM.
///
/// TartUI deliberately keeps this surface small and visible: every stored option
/// has a matching control in the launch-settings editor.
public struct RunSettings: Codable, Sendable, Hashable {
  // Display and input
  public var noGraphics: Bool
  public var vnc: Bool

  // Common launch behavior
  public var noClipboard: Bool
  public var suspendable: Bool
  public var recovery: Bool

  // Sharing
  public var directoryShares: [String]

  // Network
  public var network: NetworkMode

  public init(
    noGraphics: Bool = false,
    vnc: Bool = false,
    noClipboard: Bool = false,
    suspendable: Bool = false,
    recovery: Bool = false,
    directoryShares: [String] = [],
    network: NetworkMode = .shared
  ) {
    self.noGraphics = noGraphics
    self.vnc = vnc
    self.noClipboard = noClipboard
    self.suspendable = suspendable
    self.recovery = recovery
    self.directoryShares = directoryShares
    self.network = network
  }
}

// MARK: - Command generation

extension RunSettings {
  /// Complete argv passed to the Tart executable.
  public func arguments(vmName: String) -> [String] {
    var arguments = ["run", vmName]

    if noGraphics { arguments.append("--no-graphics") }
    if vnc { arguments.append("--vnc") }
    if noClipboard { arguments.append("--no-clipboard") }
    if suspendable { arguments.append("--suspendable") }
    if recovery { arguments.append("--recovery") }

    for share in directoryShares where !share.isEmpty {
      arguments.append("--dir=\(share)")
    }

    arguments += networkArguments()
    return arguments
  }

  /// Copy-pasteable command preview shown throughout TartUI.
  public func command(vmName: String, executable: String = "tart") -> String {
    CommandAction(arguments: arguments(vmName: vmName), executable: executable).command
  }

  /// Tart's DHCP resolver does not work for bridged networking. ARP is the
  /// built-in resolver intended for bridged VMs; the other modes keep DHCP.
  public var ipResolver: IPResolver {
    if case .bridged = network {
      return .arp
    }
    return .dhcp
  }

  private func networkArguments() -> [String] {
    switch network {
    case .shared:
      return []

    case let .bridged(interfaces):
      return interfaces
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .map { "--net-bridged=\($0)" }

    case .hostOnly:
      return ["--net-host"]

    case .softnet:
      return ["--net-softnet"]
    }
  }
}

// MARK: - Validation

extension RunSettings {
  public struct Warning: Sendable, Hashable, Identifiable {
    public let id = UUID()
    public let message: String
    public let isBlocking: Bool
  }

  public func validate() -> [Warning] {
    var warnings: [Warning] = []

    if noGraphics && !vnc {
      warnings.append(Warning(
        message: "The graphics window is disabled and no VNC mode is enabled; the VM will only be accessible through SSH.",
        isBlocking: false
      ))
    }

    if recovery && suspendable {
      warnings.append(Warning(
        message: "The VM cannot be suspended in recovery mode.",
        isBlocking: false
      ))
    }

    if case let .bridged(interfaces) = network {
      let normalized = interfaces.map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }

      if normalized.isEmpty || normalized.contains(where: \.isEmpty) {
        warnings.append(Warning(
          message: "Select at least one bridged network adapter.",
          isBlocking: true
        ))
      }

      let nonEmpty = normalized.filter { !$0.isEmpty }
      if Set(nonEmpty).count != nonEmpty.count {
        warnings.append(Warning(
          message: "Each bridged network adapter can only be added once.",
          isBlocking: true
        ))
      }
    }

    return warnings
  }

  public var hasBlockingIssues: Bool {
    validate().contains { $0.isBlocking }
  }
}
