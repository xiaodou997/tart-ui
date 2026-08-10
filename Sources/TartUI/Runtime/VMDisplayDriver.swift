import Foundation
import TartKit

/// TartUI 对虚拟机显示方式的统一描述。
///
/// 这个类型刻意不把显示实现写死在会话管理器里。第一阶段由 Tart
/// 创建原生窗口，后续可以加入内嵌 VNC，而不需要改动启动、停止和日志逻辑。
enum VMDisplayMode: String, Sendable, Equatable {
  case nativeWindow
  case headless
  case screenSharingVNC
  case experimentalVNC
}

/// 一次运行所需的完整启动计划。
///
/// UI 只生成计划，运行时服务负责执行计划。这样命令行参数不会散落在
/// View 或会话状态机里，也方便将来替换 Tart 版本或显示驱动。
struct VMRuntimeLaunchPlan: Sendable, Equatable {
  let vmName: String
  let profileName: String
  let displayMode: VMDisplayMode
  let arguments: [String]

  var commandLine: String {
    "tart " + arguments.joined(separator: " ")
  }
}

/// 显示驱动边界。
///
/// 当前实现仍然调用 Tart 自己的显示能力，但会话层只依赖这个协议。
/// 以后实现 EmbeddedVNCDisplayDriver 时，不需要让 VMStore 知道 VNC 细节。
protocol VMDisplayDriver: Sendable {
  var mode: VMDisplayMode { get }
  var ownsUserFacingWindow: Bool { get }

  func makeLaunchPlan(vmName: String, profile: RunProfile) -> VMRuntimeLaunchPlan
}

/// 当前的 Tart 显示驱动：原生窗口、无图形、Screen Sharing VNC 和实验性 VNC
/// 都仍由 Tart 负责创建；TartUI 只记录模式并统一管理生命周期。
struct TartDisplayDriver: VMDisplayDriver {
  let mode: VMDisplayMode

  var ownsUserFacingWindow: Bool {
    mode == .nativeWindow
  }

  func makeLaunchPlan(vmName: String, profile: RunProfile) -> VMRuntimeLaunchPlan {
    VMRuntimeLaunchPlan(
      vmName: vmName,
      profileName: profile.name,
      displayMode: mode,
      arguments: profile.arguments(vmName: vmName)
    )
  }

  static func forProfile(_ profile: RunProfile) -> TartDisplayDriver {
    if profile.vncExperimental {
      return TartDisplayDriver(mode: .experimentalVNC)
    }
    if profile.vnc {
      return TartDisplayDriver(mode: .screenSharingVNC)
    }
    if profile.noGraphics {
      return TartDisplayDriver(mode: .headless)
    }
    return TartDisplayDriver(mode: .nativeWindow)
  }
}
