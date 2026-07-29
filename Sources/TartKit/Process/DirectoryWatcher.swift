import Foundation

/// 监听目录内容变化。
///
/// 用来即时感知虚拟机的增删——用户可能在终端里直接 `tart create` 或 `tart delete`，
/// 绕过了界面。只靠轮询的话最长要等一个周期才看得到，体验发木。
///
/// 只监听目录本身的变化（子项增删），不递归进入每台虚拟机的目录：
/// 磁盘镜像写入会产生大量事件，递归监听纯属自找麻烦。虚拟机运行状态的变化
/// 仍然靠轮询 `tart list` 来发现，那是 tart 自己的判断，比我们猜文件更可靠。
public final class DirectoryWatcher: @unchecked Sendable {
  private let url: URL
  private let onChange: @Sendable () -> Void
  private let queue = DispatchQueue(label: "com.tartpro.directory-watcher")

  private var source: DispatchSourceFileSystemObject?
  private var descriptor: Int32 = -1
  private let lock = NSLock()

  public init(url: URL, onChange: @escaping @Sendable () -> Void) {
    self.url = url
    self.onChange = onChange
  }

  deinit {
    stop()
  }

  /// 开始监听。目录不存在时返回 false，调用方可以退回纯轮询。
  @discardableResult
  public func start() -> Bool {
    lock.lock()
    defer { lock.unlock() }

    guard source == nil else { return true }

    let fd = open(url.path, O_EVTONLY)
    guard fd >= 0 else { return false }

    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd,
      eventMask: [.write, .delete, .rename],
      queue: queue
    )

    source.setEventHandler { [onChange] in
      onChange()
    }

    source.setCancelHandler {
      close(fd)
    }

    self.descriptor = fd
    self.source = source
    source.resume()

    return true
  }

  public func stop() {
    lock.lock()
    defer { lock.unlock() }

    source?.cancel()
    source = nil
    descriptor = -1
  }
}

extension DirectoryWatcher {
  /// tart 存放本地虚拟机的目录。
  public static func tartVMsDirectory() -> URL {
    // tart 允许用 TART_HOME 改位置，跟随它以免监听错目录。
    if let custom = ProcessInfo.processInfo.environment["TART_HOME"], !custom.isEmpty {
      return URL(fileURLWithPath: custom).appendingPathComponent("vms", isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".tart/vms", isDirectory: true)
  }
}
