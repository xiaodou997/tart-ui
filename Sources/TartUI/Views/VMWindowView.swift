import SwiftUI
import Virtualization
import TartVMCore

/// 虚拟机画面的宿主视图。
///
/// 这是整个重构的落点：窗口属于 TartUI 自己。窗口的出现、隐藏、关闭都
/// 只是窗口的事，不再通过任何信号影响虚拟机——上一版里 `onDisappear`
/// 会给 helper 进程发 SIGINT，那条链路在这里根本不存在。
struct VMWindowView: View {
  let vmName: String
  @Environment(VMStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Group {
      if let machine = store.runtimeSessions?.machine(for: vmName) {
        VirtualMachineDisplay(
          virtualMachine: machine.virtualMachine,
          capturesSystemKeys: store.capturesSystemKeys(for: vmName)
        )
        .frame(
          minWidth: machine.displaySize.width / 2,
          idealWidth: machine.displaySize.width,
          minHeight: machine.displaySize.height / 2,
          idealHeight: machine.displaySize.height
        )
      } else {
        // 虚拟机已经停了（或还没起来）。窗口留着并给出说明，比直接消失
        // 更容易理解；用户关掉它也不会影响任何东西。
        ContentUnavailableView(
          L10n.text("The virtual machine is not running"),
          systemImage: "display.trianglebadge.exclamationmark",
          description: Text(L10n.format("\"%@\" has stopped.", vmName))
        )
        .frame(minWidth: 480, minHeight: 320)
      }
    }
    .navigationTitle(vmName)
  }
}

/// 把 AppKit 的 `VZVirtualMachineView` 接进 SwiftUI。
private struct VirtualMachineDisplay: NSViewRepresentable {
  let virtualMachine: VZVirtualMachine
  let capturesSystemKeys: Bool

  func makeNSView(context: Context) -> VZVirtualMachineView {
    let view = VZVirtualMachineView()
    view.virtualMachine = virtualMachine
    view.capturesSystemKeys = capturesSystemKeys
    // 让客户机跟随窗口尺寸调整分辨率。这是原生视图相对 VNC 的主要优势
    // 之一，没有理由不开。
    if #available(macOS 14, *) {
      view.automaticallyReconfiguresDisplay = true
    }
    return view
  }

  func updateNSView(_ view: VZVirtualMachineView, context: Context) {
    if view.virtualMachine !== virtualMachine {
      view.virtualMachine = virtualMachine
    }
    if view.capturesSystemKeys != capturesSystemKeys {
      view.capturesSystemKeys = capturesSystemKeys
    }
  }
}
