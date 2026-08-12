import Foundation
import Semaphore
import Virtualization

/// TartUI 与 Tart 虚拟机核心之间的门面。
///
/// 这个文件属于 TartUI，但被编译进 TartVMCore target，因此能访问 Vendor/tart
/// 里的 internal 类型，而不需要给上游源码批量加 `public`。上游那边只有两个
/// 纯移动的 commit，`git rebase upstream/main` 不会冲突。
///
/// 门面刻意只暴露 TartUI 真正需要的东西。上游重构内部实现时，只要这里的
/// 签名不变，TartUI 就不用跟着改。

// MARK: - 网络

/// 虚拟机的网络接入方式。
public enum TartNetworkMode: Sendable, Equatable {
  /// Virtualization.Framework 自带的 NAT，不需要任何受限 entitlement。
  case shared
  /// 桥接到宿主的物理网卡。需要 `com.apple.vm.networking`，
  /// 这是 Apple 的受限 entitlement，必须单独申请。
  case bridged(interfaceName: String)

  fileprivate func makeNetwork() throws -> Network {
    switch self {
    case .shared:
      return NetworkShared()
    case let .bridged(interfaceName):
      let interfaces = VZBridgedNetworkInterface.networkInterfaces
      guard let interface = interfaces.first(where: { $0.identifier == interfaceName }) else {
        let available = interfaces.map(\.identifier).joined(separator: ", ")
        throw RuntimeError.VMConfigurationError(
          "no bridged network interface named \"\(interfaceName)\"; available: \(available.isEmpty ? "(none)" : available)"
        )
      }
      return NetworkBridged(interfaces: [interface])
    }
  }

  /// 宿主上可用于桥接的网卡，供设置界面列出。
  public static var availableBridgedInterfaces: [(identifier: String, name: String)] {
    VZBridgedNetworkInterface.networkInterfaces.map { ($0.identifier, $0.localizedDisplayName ?? $0.identifier) }
  }
}

// MARK: - 目录共享

/// 一个共享给客户机的宿主目录。
///
/// 这里用结构化字段而不是 `tart run --dir` 的 `[name:]path[:options]` 字符串：
/// 那个格式是命令行的产物，界面上没有理由再拼一次字符串又解析回来。
public struct TartDirectoryShare: Sendable, Equatable {
  /// 共享名。为 nil 表示未命名。
  ///
  /// 这个区分不是可有可无的：单个未命名共享在客户机里会被直接挂到
  /// 「My Shared Files」下，而命名共享会多出一层以名字命名的目录。
  /// 给未命名共享自动编个名字会改变客户机看到的路径结构。
  public let name: String?
  public let url: URL
  public let readOnly: Bool

  public init(name: String? = nil, url: URL, readOnly: Bool = false) {
    self.name = name
    self.url = url
    self.readOnly = readOnly
  }
}

// MARK: - 启动配置

/// 创建一台虚拟机所需的全部选项。
public struct TartVMOptions: Sendable {
  public var network: TartNetworkMode
  public var directoryShares: [TartDirectoryShare]
  public var suspendable: Bool
  public var nested: Bool
  public var audio: Bool
  public var clipboard: Bool
  public var noTrackpad: Bool
  public var noPointer: Bool
  public var noKeyboard: Bool

  public init(
    network: TartNetworkMode = .shared,
    directoryShares: [TartDirectoryShare] = [],
    suspendable: Bool = false,
    nested: Bool = false,
    audio: Bool = true,
    clipboard: Bool = true,
    noTrackpad: Bool = false,
    noPointer: Bool = false,
    noKeyboard: Bool = false
  ) {
    self.network = network
    self.directoryShares = directoryShares
    self.suspendable = suspendable
    self.nested = nested
    self.audio = audio
    self.clipboard = clipboard
    self.noTrackpad = noTrackpad
    self.noPointer = noPointer
    self.noKeyboard = noKeyboard
  }
}

// MARK: - 虚拟机

/// 一台可以在 TartUI 进程内运行的虚拟机。
///
/// 与 `tart run` 子进程模型的区别：启动、关机、暂停都是直接的方法调用，
/// 不再经过信号、进程退出码和 stdout 解析。窗口由 TartUI 自己持有，
/// 窗口的显示与隐藏因此不可能再触发关机。
@MainActor
public final class TartVirtualMachine {
  private let vm: VM
  private let vmDir: VMDirectory

  /// 虚拟机目录的排他锁，必须持有到虚拟机停止为止。
  ///
  /// 它有两个作用：阻止同一台虚拟机被打开两次（两个进程写同一个 disk.img
  /// 会直接损坏客户机），以及让 `tart list` 能看出这台机器正在运行。
  /// 上游 `tart run` 在启动时加这把锁，进程内模式必须照做，否则从命令行
  /// 敲一句 tart run 就能把正在跑的虚拟机撞坏。
  private var runLock: PIDLock?

  /// 客户机控制通道。
  ///
  /// 在 `~/.tart/vms/<name>/control.sock` 上监听，把连接转发到客户机的 vsock
  /// 端口。`tart exec`、`tart ip` 这类命令都经由它进入客户机，上游 `tart run`
  /// 在虚拟机启动后立刻拉起，所以进程内模式也必须提供，否则这些命令会失效。
  private var controlSocketTask: Task<Void, Never>?

  /// 挂给 `VZVirtualMachineView` 的对象。
  public var virtualMachine: VZVirtualMachine { vm.virtualMachine }

  public var name: String { vm.name }

  /// 客户机的显示分辨率，用于给窗口定初始尺寸。
  public var displaySize: CGSize {
    CGSize(width: vm.config.display.width, height: vm.config.display.height)
  }

  /// 实际交给 Virtualization.Framework 的配置，仅用于诊断与日志。
  ///
  /// 「我们生成的配置和上游 tart 到底差在哪」这个问题，靠读源码对比是不
  /// 可靠的——今天就漏掉过一处。把真实对象暴露出来，差异可以直接打印。
  public var debugConfiguration: VZVirtualMachineConfiguration { vm.configuration }

  public var cpuCount: Int { vm.config.cpuCount }
  public var memorySize: UInt64 { vm.config.memorySize }

  /// 当前是否处于运行态。
  public var isRunning: Bool { vm.virtualMachine.state == .running }

  /// 打开 `~/.tart/vms/<name>` 下的虚拟机。
  ///
  /// - Note: 只支持本地虚拟机。OCI 镜像的拉取和克隆仍然走 tart 命令行，
  ///   那些是一次性命令，用子进程更合适。
  public init(localVMNamed name: String, options: TartVMOptions = TartVMOptions()) throws {
    // 等价于 VMStorageLocal().open(name)，但不必把 VMStorageLocal 拉进来
    // ——它还带着列举 / 创建 / 删除等我们用不到的职责，以及一个留在 CLI
    // 侧的 isFileNotFound() 依赖。
    let vmDir = VMDirectory(
      baseURL: try Config().tartHomeDir
        .appendingPathComponent("vms", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    )
    try vmDir.validate(userFriendlyName: name)
    try vmDir.baseURL.updateAccessDate()
    self.vmDir = vmDir

    self.vm = try VM(
      vmDir: vmDir,
      network: try options.network.makeNetwork(),
      directorySharingDevices: try Self.makeDirectorySharingDevices(options.directoryShares),
      suspendable: options.suspendable,
      nested: options.nested,
      audio: options.audio,
      clipboard: options.clipboard,
      noTrackpad: options.noTrackpad,
      noPointer: options.noPointer,
      noKeyboard: options.noKeyboard
    )
  }

  // MARK: 生命周期

  /// 磁盘上是否存在挂起时保存的状态。存在时下次启动会从该状态恢复。
  public var hasSuspendedState: Bool {
    FileManager.default.fileExists(atPath: vmDir.stateURL.path)
  }

  /// 启动虚拟机。返回后虚拟机进入运行态，但客户机还在引导中。
  ///
  /// 若磁盘上存在挂起状态，会自动从该状态恢复而不是冷启动。这段逻辑上游
  /// 放在 `tart run` 命令里而不是 `VM` 里，所以必须在门面这层重建，
  /// 否则挂起的虚拟机会被当成冷启动，用户的会话就丢了。
  public func start(recovery: Bool = false) async throws {
    // 先抢锁再启动。抢不到说明这台虚拟机已经在别处运行，继续下去会有两个
    // 进程同时写同一块磁盘。
    let lock = try vmDir.lock()
    guard try lock.trylock() else {
      throw RuntimeError.VMAlreadyRunning(
        "virtual machine \"\(vm.name)\" is already running"
      )
    }
    runLock = lock

    do {
      // 和 waitUntilStopped 一样，启动流程也要离开 MainActor。
      //
      // 上游 `tart run` 是在一个普通 Task 里调用 vm.start() 的，VM 内部再
      // 自己跳到 MainActor 去调 VZVirtualMachine.start()。把整条链路都压在
      // MainActor 上，客户机会在进入桌面后反复重启。
      let vm = self.vm
      let shouldResume = hasSuspendedState
      let stateURL = vmDir.stateURL
      try await Task.detached {
        guard shouldResume else {
          try await vm.start(recovery: recovery, resume: false)
          return
        }
        try await vm.virtualMachine.restoreMachineStateFrom(url: stateURL)
        try FileManager.default.removeItem(at: stateURL)
        try await vm.start(recovery: recovery, resume: true)
      }.value

      startControlSocket()
    } catch {
      try? runLock?.unlock()
      runLock = nil
      throw error
    }
  }


  /// 把当前状态存盘并停机，等价于 `tart suspend`。
  ///
  /// 与 `pause()` 的区别：`pause()` 只是让 CPU 停下来，状态仍在内存里，
  /// 进程一退出就没了；这里会把状态写进 vm 目录，重启 App 后仍能恢复。
  public func suspendToDisk() async throws {
    try vm.configuration.validateSaveRestoreSupport()
    try await vm.virtualMachine.pause()
    try await vm.virtualMachine.saveMachineStateTo(url: vmDir.stateURL)
    try await vm.virtualMachine.stop()
  }

  /// 等待客户机自行停止（关机、重启失败、崩溃）。
  ///
  /// 这个方法会一直挂起到虚拟机真的停下来为止，用来驱动 UI 的运行状态。
  private func startControlSocket() {
    let socketURL = vmDir.controlSocketURL
    let vm = self.vm
    let socket = TartControlSocket(socketURL: socketURL) { port in
      try await vm.connect(toPort: port)
    }
    controlSocketTask = Task.detached {
      do {
        try await socket.run()
      } catch {
        // 与上游一致：控制通道出错不影响虚拟机继续运行，但要能看到原因。
        FileHandle.standardError.write(Data("control socket failed: \(error)\n".utf8))
      }
    }
  }

  public func waitUntilStopped() async throws {
    defer {
      controlSocketTask?.cancel()
      controlSocketTask = nil
      // 无论正常停机还是抛错，锁都必须还回去，否则这台虚拟机在下次重启
      // TartUI 之前都会被误判成「正在运行」。
      try? runLock?.unlock()
      runLock = nil
    }

    // 关键：这段等待必须离开 MainActor。
    //
    // 上游 `tart run` 是在一个普通（非 MainActor）的 Task 里调用 vm.run()
    // 的，而 vm.run() 会一直挂起到客户机停机，其间还要处理网络与信号量。
    // 把它放在 MainActor 上运行，客户机会在进入桌面几秒后反复重启——同样
    // 的虚拟机、同样的配置，换到后台上下文就完全正常。
    let vm = self.vm
    try await Task.detached { try await vm.run() }.value
  }

  /// 请求客户机正常关机，等价于在客户机里点「关机」。
  ///
  /// 客户机可以拒绝或弹确认框，所以这个调用返回不代表已经关机；
  /// 真正的结束以 `waitUntilStopped()` 返回为准。
  public func requestStop() throws {
    try vm.virtualMachine.requestStop()
  }

  /// 立即停止虚拟机，等价于拔电源。未保存的数据会丢失。
  public func stopImmediately() async throws {
    guard vm.virtualMachine.state == .running else { return }
    try await vm.virtualMachine.stop()
  }

  /// 暂停虚拟机（内存状态保留在内存里，不落盘）。
  public func pause() async throws {
    try await vm.virtualMachine.pause()
  }

  public func resumeFromPause() async throws {
    try await vm.virtualMachine.resume()
  }

  // MARK: 内部

  /// 构造目录共享设备。
  ///
  /// 这里必须和上游 `tart run` 的分支逻辑保持一致：单个未命名共享用
  /// `VZSingleDirectoryShare`，其余用 `VZMultipleDirectoryShare`。两者在
  /// 客户机里呈现的挂载结构不同，混用会让共享目录出现在意料之外的路径。
  private static func makeDirectorySharingDevices(
    _ shares: [TartDirectoryShare]
  ) throws -> [VZDirectorySharingDeviceConfiguration] {
    guard !shares.isEmpty else { return [] }

    let device = VZVirtioFileSystemDeviceConfiguration(
      tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
    )

    if shares.count == 1, let only = shares.first, only.name == nil {
      device.share = VZSingleDirectoryShare(
        directory: VZSharedDirectory(url: only.url, readOnly: only.readOnly)
      )
      return [device]
    }

    // 多个共享时每个都必须有名字，否则无法区分——上游同样拒绝这种配置。
    var directories: [String: VZSharedDirectory] = [:]
    for share in shares {
      guard let name = share.name else {
        throw RuntimeError.VMConfigurationError(
          "when sharing multiple directories, each one must have a name"
        )
      }
      directories[name] = VZSharedDirectory(url: share.url, readOnly: share.readOnly)
    }
    device.share = VZMultipleDirectoryShare(directories: directories)
    return [device]
  }
}
