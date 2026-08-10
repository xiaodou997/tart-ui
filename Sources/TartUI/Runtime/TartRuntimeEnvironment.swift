import Foundation

/// Tart helper 的进程环境。
///
/// `TARTUI_RUNTIME_AGENT` 只由 TartUI 启动的 runtime 子进程使用。对应的
/// Tart 集成补丁在构建 helper 时临时应用，因此上游源码目录不会被永久修改。
enum TartRuntimeEnvironment {
  static func make() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["TARTUI_RUNTIME_AGENT"] = "1"
    return environment
  }
}
