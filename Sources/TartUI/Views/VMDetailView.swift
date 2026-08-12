import SwiftUI
import TartKit

struct VMDetailView: View {
  let store: VMStore
  let entry: VMListEntry

  @State private var details: VMDetails?
  @State private var detailsError: String?
  @State private var selectedProfileID: UUID?
  @State private var isEditingProfile = false
  @State private var isShowingLog = false
  @State private var isStopping = false
  @State private var isEditingConfig = false
  @State private var isRenaming = false
  @State private var isCloning = false
  @State private var isConfirmingDelete = false
  @State private var isPushing = false
  @State private var isExecuting = false
  @State private var ipAddress: String?
  @State private var isLookingUpIP = false

  private var session: VMRuntimeSession? {
    store.runtimeSessions?.session(for: entry.name)
  }

  private var currentProfile: RunProfile {
    store.profile(for: entry.name, id: selectedProfileID)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        actionBar

        if let session {
          sessionBanner(session: session)
        }

        if entry.isRunning {
          networkSection
        }

        specSection
        profileSection
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task(id: entry.id) {
      await loadDetails()
    }
    .sheet(isPresented: $isEditingProfile) {
      RunProfileEditor(
        profile: currentProfile,
        vmName: entry.name,
        onSave: { updated in
          store.saveProfile(updated, for: entry.name)
          selectedProfileID = updated.id
        }
      )
    }
    .sheet(isPresented: $isShowingLog) {
      if let session {
        SessionLogView(session: session)
      }
    }
    .sheet(isPresented: $isEditingConfig) {
      if let details {
        EditConfigSheet(
          vmName: entry.name,
          current: details,
          isRunning: entry.isRunning
        ) { changes in
          Task {
            await store.updateConfig(
              name: entry.name,
              cpuCount: changes.cpuCount,
              memoryMB: changes.memoryMB,
              display: changes.display,
              randomMAC: changes.randomMAC,
              randomSerial: changes.randomSerial,
              diskSizeGB: changes.diskSizeGB
            )
            await loadDetails()
          }
        }
      }
    }
    .sheet(isPresented: $isRenaming) {
      RenameSheet(currentName: entry.name, existingNames: otherNames) { newName in
        Task { await store.rename(name: entry.name, to: newName) }
      }
    }
    .sheet(isPresented: $isCloning) {
      CloneVMSheet(sourceName: entry.name, existingNames: allNames) { source, newName, insecure, concurrency in
        store.cloneVM(source: source, newName: newName, insecure: insecure, concurrency: concurrency)
      }
    }
    .sheet(isPresented: $isPushing) {
      PushImageSheet(localName: entry.name) { local, targets, insecure, concurrency, chunk, labels, cache in
        store.push(
          localName: local, remoteNames: targets, insecure: insecure,
          concurrency: concurrency, chunkSizeMB: chunk, labels: labels, populateCache: cache
        )
      }
    }
    .sheet(isPresented: $isExecuting) {
      ExecSheet(vmName: entry.name, store: store)
    }
    .sheet(isPresented: $isConfirmingDelete) {
      DeleteConfirmation(
        entries: [entry],
        runningNames: entry.isRunning ? [entry.name] : []
      ) {
        Task { await store.delete(names: [entry.name]) }
      }
    }
  }

  private var allNames: Set<String> {
    Set(store.entries.map(\.name))
  }

  private var otherNames: Set<String> {
    allNames.subtracting([entry.name])
  }

  // MARK: - 头部

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(entry.name)
        .font(.title2.weight(.semibold))
        .textSelection(.enabled)

      HStack(spacing: 8) {
        StatusBadge(state: entry.state)

        Text(L10n.text(entry.source == .local ? "Local VM" : "Image Cache"))
          .font(.caption)
          .foregroundStyle(.secondary)

        if entry.source == .oci {
          Text(L10n.text("Read-only"))
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
        }
      }
    }
  }

  // MARK: - 操作栏

  private var actionBar: some View {
    HStack(spacing: 10) {
      if entry.isRunning {
        Button {
          Task {
            isStopping = true
            await store.stop(vmName: entry.name)
            isStopping = false
          }
        } label: {
          Label(isStopping ? L10n.text("Stopping…") : L10n.text("Stop"), systemImage: "stop.circle")
        }
        .disabled(isStopping)

        Button {
          Task { await store.suspend(vmName: entry.name) }
        } label: {
          Label(L10n.text("Suspend"), systemImage: "pause.circle")
        }
        // tart 只允许挂起以「可挂起」方式启动的虚拟机。
        .disabled(!currentProfile.suspendable)
        .help(L10n.text(currentProfile.suspendable
          ? "Save the VM state to disk"
          : "Only VMs started with Suspendable can be suspended"))
      } else {
        Button {
          store.start(vmName: entry.name, profile: currentProfile)
        } label: {
          Label(entry.state == .suspended ? L10n.text("Resume") : L10n.text("Start"), systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(currentProfile.hasBlockingIssues)
      }

      if session != nil {
        Button {
          isShowingLog = true
        } label: {
          Label(L10n.text("Logs"), systemImage: "text.alignleft")
        }
      }

      Spacer()

      Menu {
        Button(L10n.text("Clone…")) { isCloning = true }
        Button(L10n.text("Push to Registry…")) { isPushing = true }
        Button(L10n.text("Export to File…")) { exportVM() }

        if entry.isRunning {
          Button(L10n.text("Run Command…")) { isExecuting = true }
        }

        // OCI 镜像是只读缓存，改不了也重命名不了，只能克隆或删除。
        if entry.source == .local {
          Button(L10n.text("Edit Configuration…")) { isEditingConfig = true }
            .disabled(details == nil)
          Button(L10n.text("Rename…")) { isRenaming = true }
            .disabled(entry.isRunning)
        }

        Divider()

        Button(L10n.text("Delete…"), role: .destructive) { isConfirmingDelete = true }
          .disabled(entry.isRunning)
      } label: {
        Label(L10n.text("More"), systemImage: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
  }

  private func runningBanner(session: VMRuntimeSession) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        VStack(alignment: .leading, spacing: 2) {
          Text(L10n.format("Started by TartUI with profile \"%@\"", session.profileName))
            .font(.callout)
          Text(session.equivalentCommandLine)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .lineLimit(2)
        }
        Spacer()

        if session.state.isActive {
          Button(L10n.text("Show VM Window")) {
            store.showWindow(vmName: session.vmName)
          }
        }

        Button(L10n.text("Logs")) {
          isShowingLog = true
        }
      }

      Divider()

      ForEach(Array(session.recentLines.suffix(4))) { line in
        Text(line.text)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(line.isError ? .red : .secondary)
          .textSelection(.enabled)
          .lineLimit(2)
      }
    }
    .padding(10)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
  }

  @ViewBuilder
  private func sessionBanner(session: VMRuntimeSession) -> some View {
    switch session.state {
    case .starting, .running, .stopping, .suspending:
      runningBanner(session: session)
    case let .failed(failure):
      failureBanner(failure: failure)
    case .exited, .suspended:
      // 进程内模式没有「退出码」：客户机正常停机就是停机，启动或运行期
      // 出错会走上面的 .failed 分支，带着真正的错误信息。
      EmptyView()
    }
  }

  private func failureBanner(failure: VMRuntimeFailure) -> some View {
    HStack(alignment: .top, spacing: 8) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
      VStack(alignment: .leading, spacing: 3) {
        Text(L10n.text("Failed to Start"))
          .font(.callout.weight(.semibold))
        Text(failure.message)
          .font(.callout)
          .textSelection(.enabled)
        if failure.kind == .bridgedNetworkingEntitlement {
          Text(L10n.text("Bridged networking requires Apple's restricted VM networking entitlement. Choose Shared (NAT), or request it from Apple."))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
    }
    .padding(10)
    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
  }

  // MARK: - 网络

  private var networkSection: some View {
    GroupBox(L10n.text("Network")) {
      HStack {
        Text(L10n.text("IP Address")).foregroundStyle(.secondary)
        Spacer()
        if let ipAddress {
          Text(ipAddress)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
          Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ipAddress, forType: .string)
          } label: {
            Image(systemName: "doc.on.doc")
          }
          .buttonStyle(.borderless)
          .help(L10n.text("Copy"))
        } else if isLookingUpIP {
          ProgressView().controlSize(.small)
        } else {
          Button(L10n.text("Look Up")) { lookUpIP() }
            .buttonStyle(.borderless)
        }
      }
      .font(.callout)
      .padding(.vertical, 6)
    }
  }

  private func lookUpIP() {
    isLookingUpIP = true
    Task {
      // 刚启动时网络还没就绪，让 tart 等一会儿再返回。
      ipAddress = await store.ipAddress(for: entry.name, waitSeconds: 15)
      isLookingUpIP = false
    }
  }

  private func exportVM() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(entry.name).tvm"
    panel.canCreateDirectories = true
    panel.message = L10n.text("Choose an export location. VMs can be tens of GB and may take a while to export.")

    guard panel.runModal() == .OK, let url = panel.url else { return }
    store.exportVM(name: entry.name, to: url.path)
  }

  // MARK: - 规格

  private var specSection: some View {
    GroupBox(L10n.text("Configuration")) {
      if let details {
        VStack(spacing: 0) {
          SpecRow(label: L10n.text("CPU"), value: L10n.format("%@ cores", String(details.cpuCount)))
          Divider()
          SpecRow(label: L10n.text("Memory"), value: L10n.format("%@ GB", String(format: "%.0f", details.memoryGB)))
          Divider()
          SpecRow(label: L10n.text("Display"), value: details.display.description)
          Divider()
          SpecRow(
            label: L10n.text("Disk"),
            value: L10n.format(
              "%@ GB used / %@ GB",
              String(format: "%.1f", details.allocatedSizeGB),
              String(details.diskSizeGB)
            )
          )
          Divider()
          SpecRow(label: L10n.text("System"), value: details.os == "darwin" ? "macOS" : details.os)
        }
      } else if let detailsError {
        Text(detailsError)
          .font(.callout)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 4)
      } else {
        ProgressView()
          .frame(maxWidth: .infinity)
          .padding(.vertical, 8)
      }
    }
  }

  // MARK: - 启动配置

  private var profileSection: some View {
    GroupBox(L10n.text("Run Profile")) {
      VStack(alignment: .leading, spacing: 10) {
        let available = store.profiles.profiles(for: entry.name)

        HStack {
          if available.isEmpty {
            Text(L10n.text("No profile yet; the VM will start with default arguments."))
              .font(.callout)
              .foregroundStyle(.secondary)
          } else {
            Picker(L10n.text("Profile"), selection: $selectedProfileID) {
              ForEach(available) { profile in
                Text(profile.name).tag(Optional(profile.id))
              }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
          }

          Spacer()

          Button(available.isEmpty ? L10n.text("Create Profile…") : L10n.text("Edit…")) {
            isEditingProfile = true
          }
        }

        let warnings = currentProfile.validate()
        if !warnings.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(warnings) { warning in
              Label {
              Text(L10n.text(warning.message)).font(.caption)
              } icon: {
                Image(systemName: warning.isBlocking
                  ? "exclamationmark.octagon.fill"
                  : "exclamationmark.triangle.fill")
                  .foregroundStyle(warning.isBlocking ? .red : .orange)
              }
            }
          }
        }

        // 让用户看得到实际会执行什么命令，也方便复制到终端复现问题。
        Text("tart " + currentProfile.arguments(vmName: entry.name).joined(separator: " "))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.vertical, 4)
    }
  }

  // MARK: - 数据加载

  private func loadDetails() async {
    details = nil
    detailsError = nil

    guard let client = store.client else { return }
    do {
      details = try await client.get(name: entry.name)
    } catch {
      detailsError = error.localizedDescription
    }
  }
}

private struct SpecRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack {
      Text(label)
        .foregroundStyle(.secondary)
      Spacer()
      Text(value)
        .textSelection(.enabled)
    }
    .font(.callout)
    .padding(.vertical, 6)
  }
}

struct StatusBadge: View {
  let state: VMState

  var body: some View {
    Text(label)
      .font(.caption.weight(.medium))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(color.opacity(0.15), in: Capsule())
      .foregroundStyle(color)
  }

  private var label: String {
    switch state {
    case .running: L10n.text("Running")
    case .suspended: L10n.text("Suspended")
    case .stopped: L10n.text("Stopped")
    case .unknown: L10n.text("Unknown State")
    }
  }

  private var color: Color {
    switch state {
    case .running: .green
    case .suspended: .orange
    case .stopped: .secondary
    case .unknown: .gray
    }
  }
}
