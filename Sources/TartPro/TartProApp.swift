import SwiftUI
import TartKit

@main
struct TartProApp: App {
  @State private var store = VMStore()
  @State private var selection: VMListEntry.ID?
  @State private var isCreating = false

  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    WindowGroup {
      Group {
        if store.client == nil, let error = store.loadError {
          SetupGuideView(message: error) {
            Task { await store.bootstrap() }
          }
        } else {
          NavigationSplitView {
            VStack(spacing: 0) {
              VMListView(store: store, selection: $selection)
              OperationStatusBar(center: store.operations)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .toolbar {
              ToolbarItem {
                Button {
                  isCreating = true
                } label: {
                  Label("新建虚拟机", systemImage: "plus")
                }
              }
            }
          } detail: {
            detailPane
          }
          .sheet(isPresented: $isCreating) {
            CreateVMSheet(existingNames: Set(store.entries.map(\.name))) { name, source, diskSize, format in
              store.createVM(name: name, source: source, diskSizeGB: diskSize, diskFormat: format)
            }
          }
        }
      }
      .frame(minWidth: 760, minHeight: 460)
      .task {
        // AppDelegate 拿不到 SwiftUI 的 @State，退出确认所需的数据从这里注入。
        AppDelegate.runningVMNamesProvider = { [store] in
          store.sessions?.activeVMNames ?? []
        }
        await store.bootstrap()
      }
      .alert(
        "操作失败",
        isPresented: Binding(
          get: { store.actionError != nil },
          set: { if !$0 { store.actionError = nil } }
        )
      ) {
        Button("好") { store.actionError = nil }
      } message: {
        // 直接展示 tart 的原始报错，用户才知道到底哪里出了问题。
        Text(store.actionError ?? "")
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
    if let entry = store.entry(id: selection) {
      VMDetailView(store: store, entry: entry)
    } else {
      ContentUnavailableView("未选择虚拟机", systemImage: "sidebar.left")
    }
  }
}

