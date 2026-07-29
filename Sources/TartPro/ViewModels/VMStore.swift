import Foundation
import Observation
import TartKit

/// 虚拟机列表的单一数据源。
///
/// 目前只做「拉取 + 展示」。后续阶段会在这里接入 FSEvents 监听和轮询，
/// 把三条状态通道（文件系统事件、轮询、自有子进程表）合并到同一份数据上。
@Observable
@MainActor
final class VMStore {
  private(set) var entries: [VMListEntry] = []
  private(set) var isLoading = false
  private(set) var loadError: String?

  /// tart 不可用时为 nil，界面据此显示引导页。
  private(set) var client: TartClient?
  private(set) var tartVersion: String?

  /// 启动自检：定位 tart 并确认它能跑起来。
  func bootstrap(userOverride: String? = nil) async {
    do {
      let client = try TartClient(userOverride: userOverride)
      self.tartVersion = try await client.version()
      self.client = client
      self.loadError = nil
      await refresh()
    } catch {
      // 定位失败不是「加载出错」，而是「还没配好」，界面应给出安装/指路引导。
      self.client = nil
      self.loadError = error.localizedDescription
    }
  }

  func refresh() async {
    guard let client else { return }

    isLoading = true
    defer { isLoading = false }

    do {
      entries = try await client.list()
      loadError = nil
    } catch {
      loadError = error.localizedDescription
    }
  }

  var localEntries: [VMListEntry] {
    entries.filter { $0.source == .local }
  }

  var ociEntries: [VMListEntry] {
    entries.filter { $0.source == .oci }
  }
}
