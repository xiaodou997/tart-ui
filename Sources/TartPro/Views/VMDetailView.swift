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

  private var session: RunSession? {
    store.sessions?.session(for: entry.name)
  }

  private var currentProfile: RunProfile {
    store.profile(for: entry.name, id: selectedProfileID)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        actionBar

        if let session, session.state.isActive {
          runningBanner(session: session)
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

        Text(entry.source == .local ? "本地虚拟机" : "镜像缓存")
          .font(.caption)
          .foregroundStyle(.secondary)

        if entry.source == .oci {
          Text("只读")
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
          Label(isStopping ? "正在关机…" : "关机", systemImage: "stop.circle")
        }
        .disabled(isStopping)

        Button {
          Task { await store.suspend(vmName: entry.name) }
        } label: {
          Label("挂起", systemImage: "pause.circle")
        }
        // tart 只允许挂起以「可挂起」方式启动的虚拟机。
        .disabled(!currentProfile.suspendable)
        .help(currentProfile.suspendable
          ? "把虚拟机状态存到磁盘"
          : "只有以「可挂起」选项启动的虚拟机才能挂起")
      } else {
        Button {
          store.start(vmName: entry.name, profile: currentProfile)
        } label: {
          Label(entry.state == .suspended ? "恢复运行" : "启动", systemImage: "play.fill")
        }
        .buttonStyle(.borderedProminent)
        .disabled(currentProfile.hasBlockingIssues)
      }

      if session != nil {
        Button {
          isShowingLog = true
        } label: {
          Label("日志", systemImage: "text.alignleft")
        }
      }

      Spacer()

      Menu {
        Button("克隆…") { isCloning = true }
        Button("推送到仓库…") { isPushing = true }

        // OCI 镜像是只读缓存，改不了也重命名不了，只能克隆或删除。
        if entry.source == .local {
          Button("修改配置…") { isEditingConfig = true }
            .disabled(details == nil)
          Button("重命名…") { isRenaming = true }
            .disabled(entry.isRunning)
        }

        Divider()

        Button("删除…", role: .destructive) { isConfirmingDelete = true }
          .disabled(entry.isRunning)
      } label: {
        Label("更多", systemImage: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
  }

  private func runningBanner(session: RunSession) -> some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      VStack(alignment: .leading, spacing: 2) {
        Text("由 TartPro 启动，使用配置「\(session.profileName)」")
          .font(.callout)
        Text(session.commandLine)
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .lineLimit(2)
      }
      Spacer()
    }
    .padding(10)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
  }

  // MARK: - 规格

  private var specSection: some View {
    GroupBox("配置") {
      if let details {
        VStack(spacing: 0) {
          SpecRow(label: "CPU", value: "\(details.cpuCount) 核")
          Divider()
          SpecRow(label: "内存", value: String(format: "%.0f GB", details.memoryGB))
          Divider()
          SpecRow(label: "显示", value: details.display.description)
          Divider()
          SpecRow(
            label: "磁盘",
            value: String(format: "%.1f GB 已用 / %d GB", details.allocatedSizeGB, details.diskSizeGB)
          )
          Divider()
          SpecRow(label: "系统", value: details.os == "darwin" ? "macOS" : details.os)
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
    GroupBox("启动配置") {
      VStack(alignment: .leading, spacing: 10) {
        let available = store.profiles.profiles(for: entry.name)

        HStack {
          if available.isEmpty {
            Text("尚未创建配置，将使用默认参数启动。")
              .font(.callout)
              .foregroundStyle(.secondary)
          } else {
            Picker("使用配置", selection: $selectedProfileID) {
              ForEach(available) { profile in
                Text(profile.name).tag(Optional(profile.id))
              }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
          }

          Spacer()

          Button(available.isEmpty ? "新建配置…" : "编辑…") {
            isEditingProfile = true
          }
        }

        let warnings = currentProfile.validate()
        if !warnings.isEmpty {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(warnings) { warning in
              Label {
                Text(warning.message).font(.caption)
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
    case .running: "运行中"
    case .suspended: "已挂起"
    case .stopped: "已停止"
    case .unknown: "状态未知"
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
