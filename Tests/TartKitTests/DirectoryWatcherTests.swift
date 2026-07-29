import Foundation
import Testing
@testable import TartKit

@Suite("目录监听", .serialized)
struct DirectoryWatcherTests {
  /// 建一个临时目录，用完删掉。
  private func makeTempDirectory() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("tartpro-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test("目录里新增条目时触发回调")
  func firesOnCreate() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let counter = EventCounter()
    let watcher = DirectoryWatcher(url: directory) {
      counter.increment()
    }
    #expect(watcher.start())
    defer { watcher.stop() }

    // 给监听器一点时间就位。
    try await Task.sleep(for: .milliseconds(200))

    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("new-vm"),
      withIntermediateDirectories: true
    )

    try await Task.sleep(for: .milliseconds(500))

    #expect(counter.value > 0, "新增条目后监听器没有触发")
  }

  @Test("删除条目时触发回调")
  func firesOnDelete() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let child = directory.appendingPathComponent("doomed-vm")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

    let counter = EventCounter()
    let watcher = DirectoryWatcher(url: directory) {
      counter.increment()
    }
    #expect(watcher.start())
    defer { watcher.stop() }

    try await Task.sleep(for: .milliseconds(200))

    try FileManager.default.removeItem(at: child)

    try await Task.sleep(for: .milliseconds(500))

    #expect(counter.value > 0, "删除条目后监听器没有触发")
  }

  @Test("目录不存在时启动失败而不是崩溃")
  func failsGracefullyOnMissingDirectory() {
    let watcher = DirectoryWatcher(url: URL(fileURLWithPath: "/nonexistent/path/xyz")) {}

    // 返回 false 让调用方知道要退回纯轮询。
    #expect(!watcher.start())
  }

  @Test("停止后不再触发")
  func stopsFiring() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let counter = EventCounter()
    let watcher = DirectoryWatcher(url: directory) {
      counter.increment()
    }
    #expect(watcher.start())

    try await Task.sleep(for: .milliseconds(200))
    watcher.stop()
    try await Task.sleep(for: .milliseconds(100))

    let before = counter.value

    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("after-stop"),
      withIntermediateDirectories: true
    )
    try await Task.sleep(for: .milliseconds(400))

    #expect(counter.value == before, "停止后仍然收到了事件")
  }

  @Test("重复调用 start 不会装上多个监听器")
  func startIsIdempotent() async throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let counter = EventCounter()
    let watcher = DirectoryWatcher(url: directory) {
      counter.increment()
    }
    #expect(watcher.start())
    #expect(watcher.start())
    #expect(watcher.start())
    defer { watcher.stop() }

    try await Task.sleep(for: .milliseconds(200))
    try FileManager.default.createDirectory(
      at: directory.appendingPathComponent("once"),
      withIntermediateDirectories: true
    )
    try await Task.sleep(for: .milliseconds(500))

    // 一次变更可能产生多个底层事件，这里只确认没有因为重复 start
    // 而成倍放大——三个监听器的话计数会明显偏高。
    #expect(counter.value > 0)
    #expect(counter.value < 10)
  }
}

/// 线程安全的计数器。监听回调发生在后台队列。
final class EventCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.withLock { count }
  }

  func increment() {
    lock.withLock { count += 1 }
  }
}
