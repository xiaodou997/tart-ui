import Foundation
import Virtualization

/// Lightweight UI-facing description of a host interface Tart can bridge to.
///
/// TartUI never creates or owns a virtual network here. It only asks Apple's
/// Virtualization framework for the same bridgeable host-interface inventory
/// Tart uses, then passes the chosen identifiers back to `tart run`.
struct BridgedNetworkInterfaceInfo: Identifiable, Hashable, Sendable {
  let identifier: String
  let displayName: String?

  var id: String { identifier }

  var displayLabel: String {
    guard let displayName,
          !displayName.isEmpty,
          displayName != identifier
    else {
      return identifier
    }

    return "\(displayName) — \(identifier)"
  }
}

enum BridgedNetworkInterfaceCatalog {
  static func available() -> [BridgedNetworkInterfaceInfo] {
    VZBridgedNetworkInterface.networkInterfaces
      .map {
        BridgedNetworkInterfaceInfo(
          identifier: $0.identifier,
          displayName: $0.localizedDisplayName
        )
      }
      .sorted {
        let lhs = $0.displayName ?? $0.identifier
        let rhs = $1.displayName ?? $1.identifier
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
      }
  }
}
