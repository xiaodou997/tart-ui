import Foundation

/// A named set of launch arguments for a Tart VM.
///
/// TartUI deliberately exposes only a small common subset in the UI. The model
/// keeps older fields so profiles created by previous releases continue to run
/// with the same command line even when those fields are no longer first-class
/// controls in the editor.
public struct RunProfile: Codable, Sendable, Hashable, Identifiable {
  public var id: UUID
  public var name: String

  // Display and input
  public var noGraphics: Bool
  public var vnc: Bool
  public var vncExperimental: Bool
  public var captureSystemKeys: Bool
  public var noTrackpad: Bool
  public var noPointer: Bool
  public var noKeyboard: Bool

  // Devices
  public var noAudio: Bool
  public var noClipboard: Bool
  public var suspendable: Bool
  public var nested: Bool
  public var recovery: Bool

  // Serial
  public var serial: Bool
  public var serialPath: String?

  // Storage and sharing
  public var disks: [String]
  public var rootDiskOptions: String?
  public var directoryShares: [String]
  public var rosettaTag: String?

  // Network
  public var network: NetworkMode

  public init(
    id: UUID = UUID(),
    name: String = "Default",
    noGraphics: Bool = false,
    vnc: Bool = false,
    vncExperimental: Bool = false,
    captureSystemKeys: Bool = false,
    noTrackpad: Bool = false,
    noPointer: Bool = false,
    noKeyboard: Bool = false,
    noAudio: Bool = false,
    noClipboard: Bool = false,
    suspendable: Bool = false,
    nested: Bool = false,
    recovery: Bool = false,
    serial: Bool = false,
    serialPath: String? = nil,
    disks: [String] = [],
    rootDiskOptions: String? = nil,
    directoryShares: [String] = [],
    rosettaTag: String? = nil,
    network: NetworkMode = .shared
  ) {
    self.id = id
    self.name = name
    self.noGraphics = noGraphics
    self.vnc = vnc
    self.vncExperimental = vncExperimental
    self.captureSystemKeys = captureSystemKeys
    self.noTrackpad = noTrackpad
    self.noPointer = noPointer
    self.noKeyboard = noKeyboard
    self.noAudio = noAudio
    self.noClipboard = noClipboard
    self.suspendable = suspendable
    self.nested = nested
    self.recovery = recovery
    self.serial = serial
    self.serialPath = serialPath
    self.disks = disks
    self.rootDiskOptions = rootDiskOptions
    self.directoryShares = directoryShares
    self.rosettaTag = rosettaTag
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
    if vncExperimental { arguments.append("--vnc-experimental") }
    if captureSystemKeys { arguments.append("--capture-system-keys") }
    if noTrackpad { arguments.append("--no-trackpad") }
    if noPointer { arguments.append("--no-pointer") }
    if noKeyboard { arguments.append("--no-keyboard") }

    if noAudio { arguments.append("--no-audio") }
    if noClipboard { arguments.append("--no-clipboard") }
    if suspendable { arguments.append("--suspendable") }
    if nested { arguments.append("--nested") }
    if recovery { arguments.append("--recovery") }

    if serial { arguments.append("--serial") }
    if let serialPath, !serialPath.isEmpty {
      arguments += ["--serial-path", serialPath]
    }

    for disk in disks where !disk.isEmpty {
      arguments.append("--disk=\(disk)")
    }
    if let rootDiskOptions, !rootDiskOptions.isEmpty {
      arguments.append("--root-disk-opts=\(rootDiskOptions)")
    }
    for share in directoryShares where !share.isEmpty {
      arguments.append("--dir=\(share)")
    }
    if let rosettaTag, !rosettaTag.isEmpty {
      arguments.append("--rosetta=\(rosettaTag)")
    }

    arguments += networkArguments()
    return arguments
  }

  /// Copy-pasteable command preview shown throughout TartUI.
  ///
  /// TartExecutor receives argv directly, but users expect the preview to be a
  /// valid shell command too. Quote only when necessary so simple commands stay
  /// easy to read.
  public func command(vmName: String, executable: String = "tart") -> String {
    CommandAction(arguments: arguments(vmName: vmName), executable: executable).command
  }

  private func networkArguments() -> [String] {
    switch network {
    case .shared:
      return []

    case let .bridged(interface):
      guard !interface.isEmpty else { return [] }
      return ["--net-bridged=\(interface)"]

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

    if vnc && vncExperimental {
      warnings.append(Warning(
        message: "Screen Sharing and Experimental VNC cannot be enabled together. Choose one.",
        isBlocking: true
      ))
    }

    if noGraphics && !vnc && !vncExperimental {
      warnings.append(Warning(
        message: "The graphics window is disabled and no VNC mode is enabled; the VM will only be accessible through SSH.",
        isBlocking: false
      ))
    }

    if suspendable && noAudio {
      warnings.append(Warning(
        message: "Suspendable already disables audio; disabling audio separately is unnecessary.",
        isBlocking: false
      ))
    }

    if recovery && suspendable {
      warnings.append(Warning(
        message: "The VM cannot be suspended in recovery mode.",
        isBlocking: false
      ))
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

    if serial && serialPath != nil {
      warnings.append(Warning(
        message: "Open Serial Console and External Serial Path are alternative modes; enabling both may not work as expected.",
        isBlocking: false
      ))
    }

    return warnings
  }

  public var hasBlockingIssues: Bool {
    validate().contains { $0.isBlocking }
  }
}
