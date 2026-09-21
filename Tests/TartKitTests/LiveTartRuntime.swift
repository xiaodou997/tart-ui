import Foundation
@testable import TartKit

/// Test-only discovery for suites that optionally exercise a real Tart binary.
///
/// Production code always resolves the runtime source explicitly from the user's
/// saved preference. Live tests accept either a system or managed installation.
enum LiveTartRuntime {
  static func resolve() throws -> TartRuntime {
    let locator = TartLocator()

    if let system = try? locator.resolve(preference: .system) {
      return system
    }

    return try locator.resolve(preference: .managed)
  }

  static func makeClient() throws -> TartClient {
    TartClient(runtime: try resolve())
  }

  static var isInstalled: Bool {
    (try? resolve()) != nil
  }
}
