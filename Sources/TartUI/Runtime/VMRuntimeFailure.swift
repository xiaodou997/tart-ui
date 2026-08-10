import Foundation

enum VMRuntimeFailureKind: Sendable, Equatable {
  case bridgedNetworkingEntitlement
  case generic
}

/// UI 可识别的运行时失败。
///
/// 失败类型和用户可读文本分开保存，界面不再通过 contains(errorMessage)
/// 猜测是不是桥接网络 entitlement 问题。
struct VMRuntimeFailure: Sendable, Equatable {
  let kind: VMRuntimeFailureKind
  let message: String

  init(error: any Error) {
    let message = error.localizedDescription
    self.init(message: message)
  }

  init(message: String) {
    self.message = message
    if message.contains("com.apple.vm.networking") ||
      message.contains("com.apple.developer.networking.vmnet") {
      self.kind = .bridgedNetworkingEntitlement
    } else {
      self.kind = .generic
    }
  }
}
