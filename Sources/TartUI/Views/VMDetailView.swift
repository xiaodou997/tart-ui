import SwiftUI
import TartKit

struct VMDetailView: View {
  let store: VMStore
  let entry: VMListEntry

  @State private var details: VMDetails?
  @State private var detailsError: String?
  @State private var selectedProfileID: UUID?
  @State private var isEditingProfile = false
  @State private var isStopping = false
  @State private var isEditingConfig = false
  @State private var isRenaming = false
  @State private var isCloning = false
  @State private var isConfirmingDelete = false
  @State private var isPushing = false
  @State private var isExecuting = false
  @State private var ipAddress: String?
  @State private var isLookingUpIP = false

  private var currentProfile: RunProfile {
    store.profile(for: entry.name, id: selectedProfileID)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        actionBar

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
          localName: local,
          remoteNames: targets,
          insecure: insecure,
          concurrency: concurrency,
          chunkSizeMB: chunk,
          labels: labels,
          populateCache: cache
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
        .help(L10n.text("Ask tart to save the VM state to disk"))
      } else {
        Button {
          store.start(vmName: entry.name, profile: currentProfile)
        } label: {
          Label(
            entry.state == .suspended ? L10n.text("Resume") : L10n.text("Start"),
            systemImage: "play.fill"
          )
        }
        .buttonStyle(.borderedProminent)
        .disabled(currentProfile.hasBlockingIssues)
      }

      Spacer()

      Menu {
        Button(L10n.text("Clone…")) { isCloning = true }
        Button(L10n.text("Push to Registry…")) { isPushing = true }
        Button(L10n.text("Export to File…")) { exportVM() }

        if entry.isRunning {
          Button(L10n.text("Run Command…")) { isExecuting = true }
        }

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

        Text("tart " + currentProfile.arguments(vmName: entry.name).joined(separator: " "))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.vertical, 4)
    }
  }

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
