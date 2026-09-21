import Foundation

/// A named set of the common `tart run` options exposed by TartUI.
///
/// TartUI intentionally keeps this model small: if an option is not visible in
/// the current run-profile editor, it is not silently preserved or executed.
public struct RunProfile: Codable, Sendable, Hashable, Identifiable {
  public var id: UUID
  public var name: String

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
    id: UUID = UUID(),
    name: String = "Default",
    noGraphics: Bool = false,
    vnc: Bool = false,
    noClipboard: Bool = false,
    suspendable: Bool = false,
    recovery: Bool = false,
    directoryShares: [String] = [],
    network: NetworkMode = .shared
  ) {
    self.id = id
    self.name = name
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

extension RunProfile {
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

    case let .softnet(options):
      var arguments = ["--net-softnet"]
      if !options.allowedCIDRs.isEmpty {
        arguments.append("--net-softnet-allow=\(options.allowedCIDRs.joined(separator: ","))")
      }
      if !options.blockedCIDRs.isEmpty {
        arguments.append("--net-softnet-block=\(options.blockedCIDRs.joined(separator: ","))")
      }
      if !options.exposedPorts.isEmpty {
        let spec = options.exposedPorts.map(\.argumentValue).joined(separator: ",")
        arguments.append("--net-softnet-expose=\(spec)")
      }
      return arguments
    }
  }
}

// MARK: - Validation

extension RunProfile {
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

    if case let .softnet(options) = network {
      for port in options.exposedPorts {
        if !(1...65535).contains(port.hostPort) || !(1...65535).contains(port.guestPort) {
          warnings.append(Warning(
            message: "Port \(port.argumentValue) is outside the valid range 1–65535.",
            isBlocking: true
          ))
        }
      }

      if !options.exposedPorts.isEmpty && options.allowedCIDRs.isEmpty {
        warnings.append(Warning(
          message: "Port forwarding is configured without allowed networks; Softnet's default restrictions may block external connections.",
          isBlocking: false
        ))
      }
    }

    return warnings
  }

  public var hasBlockingIssues: Bool {
    validate().contains { $0.isBlocking }
  }
}
