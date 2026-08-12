import SwiftUI
import TartKit

@main
struct TartUIApp: App {
  @State private var store = VMStore()
  @State private var languageStore = AppLanguageStore()
  @State private var hasBootstrapped = false
  @State private var selection: VMListEntry.ID?
  @State private var isCreating = false
  @State private var isPulling = false
  @State private var isManagingRegistry = false
  @State private var isPruning = false

  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @Environment(\.openWindow) private var openWindow

  var body: some Scene {
    WindowGroup {
      Group {
        if store.client == nil, let error = store.loadError {
          SetupGuideView(
            message: error,
            isInstalling: store.isInstallingRuntime,
            onInstall: { Task { await store.installLatestRuntime() } },
            onRetry: {
              let override = TartLocator.storedUserOverride()
              Task { await store.bootstrap(userOverride: override?.isEmpty == false ? override : nil) }
            }
          )
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
                  Button(L10n.text("Create VM…")) { isCreating = true }
                  Button(L10n.text("Pull Image…")) { isPulling = true }
                  Button(L10n.text("Import from File…")) { importVM() }
                  Divider()
                  Button(L10n.text("Prune Disk Space…")) { isPruning = true }
                  Button(L10n.text("Registry Accounts…")) { isManagingRegistry = true }
                } label: {
                  Label(L10n.text("New"), systemImage: "plus")
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
      .id(languageStore.selection)
      .environment(\.locale, languageStore.locale)
      .frame(minWidth: 760, minHeight: 460)
      .task {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        // AppDelegate 拿不到 SwiftUI 的 @State，退出确认所需的数据从这里注入。
        AppDelegate.runningVMNamesProvider = { [store] in
          store.runtimeSessions?.activeVMNames ?? []
        }
        // 进程退出前必须把虚拟机停稳：它们跑在本进程内，进程没了等于断电。
        AppDelegate.shutdownAllVMs = { [store] in
          await store.runtimeSessions?.shutdownAll()
        }
        // openWindow 只能从视图环境里取，注入给 store 后协调器才能把
        // 虚拟机窗口叫出来，而不必自己知道 SwiftUI 的存在。
        store.windowOpener = { vmName in
          openWindow(id: Self.vmWindowID, value: vmName)
        }
        let override = TartLocator.storedUserOverride()
        await store.bootstrap(userOverride: override?.isEmpty == false ? override : nil)
      }
      .alert(
        L10n.text("Operation Failed"),
        isPresented: Binding(
          get: { store.actionError != nil },
          set: { if !$0 { store.actionError = nil } }
        )
      ) {
        Button(L10n.text("OK")) { store.actionError = nil }
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
        Button(L10n.text("Refresh")) {
          Task { await store.refresh() }
        }
        .keyboardShortcut("r")
      }
    }

    // 每台运行中的虚拟机一个窗口，按虚拟机名索引。
    //
    // 窗口的开关与虚拟机生命周期完全解耦：关掉窗口只是关窗口，虚拟机继续
    // 在后台跑，再点「显示虚拟机窗口」就回来了。上一版里窗口消失会给
    // helper 发 SIGINT 把虚拟机关掉，那正是「反复重启开机画面」的根源。
    WindowGroup(id: Self.vmWindowID, for: String.self) { $vmName in
      if let vmName {
        VMWindowView(vmName: vmName)
          .environment(store)
          .environment(\.locale, languageStore.locale)
          .id(languageStore.selection)
      }
    }

    Settings {
      SettingsView(store: store, languageStore: languageStore)
        .id(languageStore.selection)
        .environment(\.locale, languageStore.locale)
    }
  }

  static let vmWindowID = "vm-display"

  /// 从导出文件恢复虚拟机。
  private func importVM() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = L10n.text("Choose a file exported by tart export")

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
      ContentUnavailableView(L10n.text("No VM Selected"), systemImage: "sidebar.left")
    }
  }
}
