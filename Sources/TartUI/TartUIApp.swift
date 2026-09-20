import SwiftUI
import TartKit

@main
struct TartUIApp: App {
  @State private var store = VMStore()
  @State private var languageStore = AppLanguageStore()
  @State private var updateStore = AppUpdateStore()
  @State private var hasBootstrapped = false
  @State private var selection: VMListEntry.ID?
  @State private var creationKind: CreateVMKind?
  @State private var isCloningImage = false
  @State private var isPulling = false
  @State private var isManagingRegistry = false
  @State private var isPruning = false

  var body: some Scene {
    WindowGroup {
      Group {
        if store.client == nil, let error = store.loadError {
          SetupGuideView(
            message: error,
            isInstalling: store.isInstallingRuntime,
            onInstall: { Task { await store.installLatestRuntime() } },
            onChooseExisting: { path in
              Task { _ = await store.applyRuntimePath(path) }
            },
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
                  Button(L10n.text("Clone Image…")) { isCloningImage = true }
                  Button(L10n.text("Create macOS VM…")) { creationKind = .macOS }
                  Button(L10n.text("Create Linux VM…")) { creationKind = .linux }
                  Divider()
                  Button(L10n.text("Cache Image…")) { isPulling = true }
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
          .sheet(item: $creationKind) { kind in
            CreateVMSheet(
              kind: kind,
              existingNames: Set(store.entries.map(\.name))
            ) { name, source, diskSize, format in
              store.createVM(name: name, source: source, diskSizeGB: diskSize, diskFormat: format)
            }
          }
          .sheet(isPresented: $isCloningImage) {
            CloneImageSheet(
              existingNames: Set(store.entries.map(\.name)),
              cachedReferences: store.ociEntries.map(\.name)
            ) { source, newName, insecure in
              store.cloneVM(source: source, newName: newName, insecure: insecure)
            }
          }
          .sheet(isPresented: $isPulling) {
            PullImageSheet { reference, insecure in
              store.pull(reference: reference, insecure: insecure)
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

        async let updateCheck: Void = updateStore.check()

        let override = TartLocator.storedUserOverride()
        await store.bootstrap(userOverride: override?.isEmpty == false ? override : nil)
        await updateCheck
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
        Text(store.actionError ?? "")
      }
    }
    .defaultSize(width: 960, height: 600)
    .commands {
      TartUICommands {
        Task { await store.refresh() }
      }
    }

    Window("About TartUI", id: "about") {
      AboutView(store: store, updateStore: updateStore)
        .id(languageStore.selection)
        .environment(\.locale, languageStore.locale)
    }
    .windowResizability(.contentSize)

    Settings {
      SettingsView(store: store, languageStore: languageStore)
        .id(languageStore.selection)
        .environment(\.locale, languageStore.locale)
    }
  }

  private func importVM() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.message = L10n.text("Choose a file exported by tart export")

    guard panel.runModal() == .OK, let url = panel.url else { return }

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
      HomeActionsView(
        onCloneImage: { isCloningImage = true },
        onCreateMacOS: { creationKind = .macOS },
        onCreateLinux: { creationKind = .linux },
        onCacheImage: { isPulling = true }
      )
    }
  }
}

private struct HomeActionsView: View {
  let onCloneImage: () -> Void
  let onCreateMacOS: () -> Void
  let onCreateLinux: () -> Void
  let onCacheImage: () -> Void

  var body: some View {
    VStack(spacing: 22) {
      VStack(spacing: 6) {
        Image(systemName: "desktopcomputer")
          .font(.system(size: 34))
          .foregroundStyle(.secondary)

        Text(L10n.text("Create or Clone a VM"))
          .font(.title2.weight(.semibold))

        Text(L10n.text("Most VMs start from an existing OCI image. Clone one into a local VM, or create a blank VM when you need one."))
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 520)
      }

      HStack(spacing: 12) {
        Button(action: onCloneImage) {
          VStack(spacing: 7) {
            Image(systemName: "square.and.arrow.down.on.square")
              .font(.title3)
            Text(L10n.text("Clone Image"))
              .font(.headline)
            Text(L10n.text("Recommended"))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .frame(width: 155, height: 86)
        }
        .buttonStyle(.borderedProminent)

        Button(action: onCreateMacOS) {
          VStack(spacing: 7) {
            Image(systemName: "apple.logo")
              .font(.title3)
            Text(L10n.text("Create macOS VM"))
              .font(.headline)
          }
          .frame(width: 155, height: 86)
        }
        .buttonStyle(.bordered)

        Button(action: onCreateLinux) {
          VStack(spacing: 7) {
            Image(systemName: "terminal")
              .font(.title3)
            Text(L10n.text("Create Linux VM"))
              .font(.headline)
          }
          .frame(width: 155, height: 86)
        }
        .buttonStyle(.bordered)
      }

      Button(L10n.text("Cache Image Only…"), action: onCacheImage)
        .buttonStyle(.borderless)
        .help(L10n.text("Run tart pull without creating a local VM"))
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding(32)
  }
}
