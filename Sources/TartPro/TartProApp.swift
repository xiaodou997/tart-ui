import SwiftUI
import TartKit

@main
struct TartProApp: App {
  @State private var store = VMStore()
  @State private var selection: VMListEntry.ID?
  @State private var isCreating = false
  @State private var isPulling = false
  @State private var isManagingRegistry = false
  @State private var isPruning = false

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
                Menu {
                  Button("新建虚拟机…") { isCreating = true }
                  Button("拉取镜像…") { isPulling = true }
                  Button("从文件导入…") { importVM() }
                  Divider()
                  Button("清理磁盘空间…") { isPruning = true }
                  Button("仓库账号…") { isManagingRegistry = true }
                } label: {
                  Label("新建", systemImage: "plus")
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
          .sheet(isPresented: $isPulling) {
            PullImageSheet(recentReferences: store.ociEntries.map(\.name)) { reference, insecure, concurrency in
              store.pull(reference: reference, insecure: insecure, concurrency: concurrency)
            }
          }
          .sheet(isPresented: $isPruning) {
            PruneSheet(store: store)
          }
          .sheet(isPresented: $isManagingRegistry) {
            RegistryLoginSheet(
              onLogin: { host, user, password, insecure, validate in
                await store.login(
                  host: host, username: user, password: password,
                  insecure: insecure, validate: validate
                )
              },
              onLogout: { host in await store.logout(host: host) }
            )
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

  /// 从导出文件恢复虚拟机。
  private func importVM() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = "选择用 tart export 导出的文件"

    guard panel.runModal() == .OK, let url = panel.url else { return }

    // 用文件名作为默认虚拟机名，去掉扩展名；撞名就加序号。
    let base = url.deletingPathExtension().lastPathComponent
    let existing = Set(store.entries.map(\.name))
    var name = base
    var index = 2
    while existing.contains(name) {
      name = "\(base)-\(index)"
      index += 1
    }

    store.importVM(from: url.path, name: name)
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

