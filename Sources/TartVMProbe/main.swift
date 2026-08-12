import AppKit
import Foundation
import TartVMCore
import Virtualization

/// 诊断工具：用 TartVMCore 直接启动一台虚拟机，并打印完整的配置。
///
/// 存在的理由是二分：TartUI 里虚拟机会反复重启，命令行 tart 跑同一台却
/// 正常。这个程序用的是和 TartUI 完全相同的 TartVMCore 代码路径，但不带
/// 任何 TartUI 的界面逻辑——它循环就说明问题在配置层，它正常就说明问题
/// 在界面层。
///
/// 用法：TartVMProbe <vm-name> [--dir <path>] [--window]
///
/// 这是开发诊断工具，不随 App 分发。它的价值在于二分：用与 TartUI 完全相同
/// 的 TartVMCore 路径启动虚拟机，但不带任何界面逻辑，可以判断问题出在运行时
/// 还是界面层。

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
  FileHandle.standardError.write(Data("usage: TartVMProbe <vm-name> [--dir <path>] [--window]\n".utf8))
  exit(2)
}

let vmName = arguments[1]
var shareURL: URL?
var wantsWindow = false

var index = 2
while index < arguments.count {
  switch arguments[index] {
  case "--dir":
    index += 1
    if index < arguments.count {
      shareURL = URL(fileURLWithPath: arguments[index], isDirectory: true)
    }
  case "--window":
    wantsWindow = true
  default:
    break
  }
  index += 1
}

@MainActor
func describe(_ configuration: VZVirtualMachineConfiguration) {
  print("=== VZVirtualMachineConfiguration ===")
  print("cpuCount:    \(configuration.cpuCount)")
  print("memorySize:  \(configuration.memorySize) (\(configuration.memorySize / 1024 / 1024 / 1024) GB)")
  print("bootLoader:  \(String(describing: configuration.bootLoader))")
  print("platform:    \(type(of: configuration.platform))")
  print("storage:     \(configuration.storageDevices.count) -> \(configuration.storageDevices.map { type(of: $0) })")
  print("network:     \(configuration.networkDevices.count) -> \(configuration.networkDevices.map { String(describing: $0.attachment) })")
  print("directories: \(configuration.directorySharingDevices.count)")
  for device in configuration.directorySharingDevices {
    if let fs = device as? VZVirtioFileSystemDeviceConfiguration {
      print("   tag=\(fs.tag) share=\(String(describing: fs.share))")
    }
  }
  print("serial:      \(configuration.serialPorts.count)")
  print("audio:       \(configuration.audioDevices.count)")
  print("keyboards:   \(configuration.keyboards.map { type(of: $0) })")
  print("pointing:    \(configuration.pointingDevices.map { type(of: $0) })")
  print("graphics:    \(configuration.graphicsDevices.count)")
  print("socket:      \(configuration.socketDevices.count)")
  print("entropy:     \(configuration.entropyDevices.count)")
  print("memBalloon:  \(configuration.memoryBalloonDevices.count)")
  print("console:     \(configuration.consoleDevices.count)")
  print("====================================")
}

@MainActor
final class Probe {
  var machine: TartVirtualMachine?

  func run() async {
    do {
      var options = TartVMOptions()
      if let shareURL {
        // 与 TartUI 一致：未命名的单个共享。
        options.directoryShares = [TartDirectoryShare(name: nil, url: shareURL)]
      }

      let machine = try TartVirtualMachine(localVMNamed: vmName, options: options)
      self.machine = machine
      print("[probe] created \(vmName), display=\(machine.displaySize)")
      describe(machine.debugConfiguration)

      try await machine.start()
      print("[probe] started; waiting for guest to stop. Press Ctrl+C to abort.")

      if wantsWindow {
        showWindow(for: machine)
      }

      try await machine.waitUntilStopped()
      print("[probe] guest stopped")
      exit(0)
    } catch {
      print("[probe] FAILED: \(error)")
      exit(1)
    }
  }

  private func showWindow(for machine: TartVirtualMachine) {
    let view = VZVirtualMachineView()
    view.virtualMachine = machine.virtualMachine
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: machine.displaySize),
      styleMask: [.titled, .closable, .resizable, .miniaturizable],
      backing: .buffered,
      defer: false
    )
    window.title = "\(vmName) (probe)"
    window.contentView = view
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
}

let probe = Probe()
NSApplication.shared.setActivationPolicy(wantsWindow ? .regular : .prohibited)
Task { @MainActor in await probe.run() }
NSApplication.shared.run()
