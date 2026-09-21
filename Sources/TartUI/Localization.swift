import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable {
  case system
  case english
  case simplifiedChinese

  static let defaultsKey = "TartUILanguage"

  var id: String { rawValue }

  @MainActor
  var title: String {
    switch self {
    case .system: L10n.text("System Default")
    case .english: "English"
    case .simplifiedChinese: "简体中文"
    }
  }

  var locale: Locale {
    switch self {
    case .system: .autoupdatingCurrent
    case .english: Locale(identifier: "en")
    case .simplifiedChinese: Locale(identifier: "zh-Hans")
    }
  }

  fileprivate var localizationName: String? {
    switch self {
    case .system: nil
    case .english: "en"
    case .simplifiedChinese: "zh-Hans"
    }
  }
}

/// 应用语言偏好。首次启动明确使用英文，用户也可以改回跟随系统。
@Observable
@MainActor
final class AppLanguageStore {
  private let defaults: UserDefaults

  var selection: AppLanguage {
    didSet {
      defaults.set(selection.rawValue, forKey: AppLanguage.defaultsKey)
    }
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let rawValue = defaults.string(forKey: AppLanguage.defaultsKey),
       let stored = AppLanguage(rawValue: rawValue) {
      self.selection = stored
    } else {
      self.selection = .english
    }
  }

  var locale: Locale { selection.locale }
}

/// UI localization backed by TartUI's packaged SwiftPM resource bundle.
///
/// SwiftPM's generated `Bundle.module` accessor contains an absolute build
/// directory fallback. That is useful while developing, but a manually
/// assembled macOS app must resolve its resources from the app bundle itself.
/// Prefer `Contents/Resources/TartUI_TartUI.bundle` in a packaged app and use
/// `Bundle.module` only in SwiftPM development/test environments.
@MainActor
enum L10n {
  static func text(_ key: String) -> String {
    localizedBundle.localizedString(forKey: key, value: key, table: nil)
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), arguments: arguments)
  }

  private static var localizedBundle: Bundle {
    let defaults = UserDefaults.standard
    let language = defaults.string(forKey: AppLanguage.defaultsKey)
      .flatMap(AppLanguage.init(rawValue:)) ?? .english

    let resources = resourceBundle

    guard let localizationName = language.localizationName,
          let url = resources.url(forResource: localizationName, withExtension: "lproj"),
          let bundle = Bundle(url: url)
    else {
      return resources
    }
    return bundle
  }

  private static var resourceBundle: Bundle {
    if let resourceURL = Bundle.main.resourceURL {
      let packagedURL = resourceURL.appendingPathComponent("TartUI_TartUI.bundle", isDirectory: true)
      if let packagedBundle = Bundle(url: packagedURL) {
        return packagedBundle
      }
    }

    // SwiftPM tests and direct executable launches use the generated module bundle.
    return Bundle.module
  }
}
