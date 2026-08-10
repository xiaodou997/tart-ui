import Foundation

/// TartKit 对外抛出的统一错误类型。
public enum TartError: Error, Sendable {
  /// 在任何已知位置都没有找到 tart 可执行文件。
  case binaryNotFound(searchedPaths: [String])

  /// 找到了文件，但它不可执行。
  case binaryNotExecutable(path: String)

  /// 找到了 tart，但版本低于 TartKit 支持的下限。
  case unsupportedVersion(found: String, minimum: String)

  /// 无法启动子进程（路径失效、权限不足等）。
  case launchFailed(underlying: any Error)

  /// tart 以非零状态码退出。stderr 原文一并带出，UI 可以直接展示给用户。
  case commandFailed(command: [String], exitCode: Int32, stderr: String)

  /// tart 的输出无法按预期结构解码。
  ///
  /// 上游一旦改动 JSON schema 就会走到这里，所以 `raw` 必须保留，
  /// 否则用户只会看到一句无从下手的「解析失败」。
  case decodingFailed(command: [String], raw: String, underlying: any Error)

  /// 命令被取消（用户主动中止，或调用方的 Task 被取消）。
  case cancelled(command: [String])
}

extension TartError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case let .binaryNotFound(searchedPaths):
      return "Could not find the tart executable. Searched: \(searchedPaths.joined(separator: ", "))"
    case let .binaryNotExecutable(path):
      return "\(path) exists but is not executable."
    case let .unsupportedVersion(found, minimum):
      return "The tart version is too old: found \(found), but \(minimum) or newer is required."
    case let .launchFailed(underlying):
      return "Could not launch tart: \(underlying.localizedDescription)"
    case let .commandFailed(command, exitCode, stderr):
      let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      let suffix = detail.isEmpty ? "" : "\n\(detail)"
      return "Command `tart \(command.joined(separator: " "))` failed (exit code \(exitCode))\(suffix)"
    case let .decodingFailed(command, _, underlying):
      return "Could not decode the output of `tart \(command.joined(separator: " "))`: \(underlying.localizedDescription)"
    case let .cancelled(command):
      return "Command `tart \(command.joined(separator: " "))` was cancelled."
    }
  }
}
