import SwiftUI
import TartKit

@main
struct TartProApp: App {
  @State private var store = VMStore()
  @State private var selection: VMListEntry.ID?

  var body: some Scene {
    WindowGroup {
      Group {
        if store.client == nil, let error = store.loadError {
          SetupGuideView(message: error) {
            Task { await store.bootstrap() }
          }
        } else {
          NavigationSplitView {
            VMListView(store: store, selection: $selection)
              .navigationSplitViewColumnWidth(min: 220, ideal: 260)
          } detail: {
            detailPane
          }
        }
      }
      .frame(minWidth: 760, minHeight: 460)
      .task {
        await store.bootstrap()
      }
    }
    // minWidth 只是下限，不决定初始尺寸——不给 defaultSize 的话
    // 窗口会缩到内容的固有大小。
    .defaultSize(width: 960, height: 600)
    .commands {
      CommandGroup(after: .newItem) {
        Button("刷新") {
          Task { await store.refresh() }
        }
        .keyboardShortcut("r")
      }
    }
  }

  @ViewBuilder
  private var detailPane: some View {
    if let selection, let entry = store.entries.first(where: { $0.id == selection }) {
      // 详情面板的完整实现在下一阶段；先把选中链路打通。
      VStack(alignment: .leading, spacing: 8) {
        Text(entry.name).font(.title2.weight(.semibold))
        Text("来源：\(entry.source == .local ? "本地" : "镜像缓存")")
        Text("状态：\(entry.state.rawValue)")
        Text("磁盘：\(entry.allocatedSizeGB) GB / \(entry.diskSizeGB) GB")
        Spacer()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding()
    } else {
      ContentUnavailableView("未选择虚拟机", systemImage: "sidebar.left")
    }
  }
}

