import Foundation

/// 宿主运行时的版本标识。
///
/// 这个类型替代了 `Vendor/tart/Sources/tart/CI/CI.swift`，后者把版本号写成
/// `${VERSION}` 占位符，由上游发布流程（`.ci/set-version.sh` + goreleaser）
/// 在打包时替换。我们直接编译源码，不走那条发布流程，占位符不会被替换，
/// `CI.version` 就会变成字符串 "SNAPSHOT"。
///
/// 这不是无害的：`VM.craftConfiguration` 会创建一个名为
/// `tart-version-<版本>` 的 console 设备，上游注释写明它用于
/// 「host feature checks in the guest agent software」。客户机里的
/// guest agent 读到无法解析的版本时，会每隔十几秒重启一次客户机——现象是
/// 进入桌面几秒后回到开机画面，且走的是完整关机流程而不是崩溃。
///
/// 所以这里给出一个真实的版本号，而不是让占位符漏到运行期。
enum CI {
  /// 与内置 Tart 运行时对应的版本号。
  ///
  /// 更新 `Vendor/tart` submodule 时必须同步这里，否则 guest agent 会按
  /// 一个不存在的宿主版本去判断可用特性。
  static let version = "2.35.0"

  static var release: String? { "tart@\(version)" }
}
