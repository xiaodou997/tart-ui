import Foundation
import Testing
@testable import TartUI

@Suite("应用语言")
@MainActor
struct LocalizationTests {
  @Test("首次启动默认英文并保存用户选择")
  func defaultsToEnglishAndPersistsSelection() throws {
    let suiteName = "TartUI.LocalizationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let initial = AppLanguageStore(defaults: defaults)
    #expect(initial.selection == .english)

    initial.selection = .simplifiedChinese
    let reloaded = AppLanguageStore(defaults: defaults)
    #expect(reloaded.selection == .simplifiedChinese)
    #expect(reloaded.locale.identifier == "zh-Hans")
  }
}
