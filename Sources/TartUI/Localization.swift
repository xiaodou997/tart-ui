import Foundation

/// UI localization backed by the app bundle's string tables.
///
/// The executable is assembled into a real `.app` by `scripts/bundle.sh`, so
/// `Bundle.module` resolves to the localized resources packaged with TartUI.
enum L10n {
  static func text(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: nil)
  }

  static func format(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: text(key), arguments: arguments)
  }
}
