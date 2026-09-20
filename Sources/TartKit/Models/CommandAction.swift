import Foundation

/// A Tart CLI invocation before it is executed.
///
/// The same value is used for command previews, operation history, and actual
/// process execution so TartUI cannot silently show different arguments from
/// the ones it passes to Tart.
public struct CommandAction: Sendable, Hashable {
  public let executable: String
  public let arguments: [String]

  public init(arguments: [String], executable: String = "tart") {
    self.executable = executable
    self.arguments = arguments
  }

  /// A shell-safe command that users can copy and run in Terminal.
  public var command: String {
    ([executable] + arguments)
      .map(Self.shellQuote)
      .joined(separator: " ")
  }

  private static func shellQuote(_ argument: String) -> String {
    guard !argument.isEmpty else { return "''" }

    let safe = CharacterSet.alphanumerics
      .union(CharacterSet(charactersIn: "-._/:=,+@%~"))

    if argument.unicodeScalars.allSatisfy({ safe.contains($0) }) {
      return argument
    }

    return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}
