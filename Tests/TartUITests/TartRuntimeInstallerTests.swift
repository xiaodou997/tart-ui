import Foundation
import Testing
@testable import TartUI

@Suite("Tart runtime versions")
struct TartRuntimeInstallerTests {
  @Test("semantic versions compare numerically")
  func comparesVersionsNumerically() {
    #expect(TartRuntimeInstaller.isVersion("2.38.0", newerThan: "2.37.9"))
    #expect(TartRuntimeInstaller.isVersion("2.10.0", newerThan: "2.9.9"))
    #expect(!TartRuntimeInstaller.isVersion("2.37.0", newerThan: "2.37.0"))
    #expect(!TartRuntimeInstaller.isVersion("2.36.9", newerThan: "2.37.0"))
  }

  @Test("version prefixes and missing patch components are tolerated")
  func toleratesCommonVersionForms() {
    #expect(TartRuntimeInstaller.compareVersions("v2.37.0", "2.37") == .orderedSame)
    #expect(TartRuntimeInstaller.compareVersions("2.37.1", "v2.37") == .orderedDescending)
  }
}
