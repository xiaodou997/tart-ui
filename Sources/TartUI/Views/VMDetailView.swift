import SwiftUI
import TartKit

struct VMDetailView: View {
  let store: VMStore
  let entry: VMListEntry

  @State private var details: VMDetails?
  @State private var detailsError: String?
  @State private var isEditingRunSettings = false
  @State private var isStopping = false
  @State private var isEditingConfig = false
  @State private var isCloning = false
  @State private var isConfirmingDelete = false
  @State private var ipAddress: String?
  @State private var isLookingUpIP = false

  private var currentSettings: RunSettings {
    store.launchSettings(for: entry.name)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        header
        actionBar

        if entry.source == .local {
          if entry.isRunning {
            runningCommandHint
          }

          launchSettingsSection

          if entry.isRunning {
            networkSection
          }

          specSection
        } else {
          cacheSection
        }
      }
      .padding(20)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .task(id: entry.id) {
      if entry.source == .local {
        await loadDetails()
      } else {
        details = nil
        detailsError = nil
      }
    }
    .sheet(isPresented: $isEditingRunSettings) {
      RunSettingsEditor(
        settings: currentSettings,
        vmName: entry.name,
        onSave: { updated in
          store.saveLaunchSettings(updated, for: entry.name)
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
    .sheet(isPresented: $isCloning) {
      CloneVMSheet(sourceName: entry.name, existingNames: allNames) { source, newName, insecure, concurrency in
        store.cloneVM(source: source, newName: newName, insecure: insecure, concurrency: concurrency)
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

  private var header: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(entry.name)
        .font(.title2.weight(.semibold))
        .textSelection(.enabled)

      HStack(spacing: 8) {
        if entry.source == .local {
          StatusBadge(state: entry.state)

          Text(L10n.text("Local VM"))
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Label(L10n.text("OCI Image Cache"), systemImage: "shippingbox")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

          Text(L10n.text("Not runnable"))
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
        }
      }
    }
  }

  @ViewBuilder
  private var actionBar: some View {
    if entry.source == .local {
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
          .buttonStyle(.glassProminent)
          .disabled(isStopping)
          .help(CommandAction(arguments: ["stop", entry.name]).command)

          Button {
            Task { await store.suspend(vmName: entry.name) }
          } label: {
            Label(L10n.text("Suspend"), systemImage: "pause.circle")
          }
          .buttonStyle(.glass)
          .help(CommandAction(arguments: ["suspend", entry.name]).command)
        } else {
          Button {
            store.start(vmName: entry.name, settings: currentSettings)
          } label: {
            Label(
              entry.state == .suspended ? L10n.text("Resume") : L10n.text("Start"),
              systemImage: "play.fill"
            )
          }
          .buttonStyle(.glassProminent)
          .disabled(currentSettings.hasBlockingIssues)
          .help(currentSettings.command(vmName: entry.name))
        }

        Spacer()

        Button {
          isCloning = true
        } label: {
          Label(L10n.text("Clone"), systemImage: "plus.square.on.square")
        }
        .buttonStyle(.glass)

        Button(role: .destructive) {
          isConfirmingDelete = true
        } label: {
          Label(L10n.text("Delete"), systemImage: "trash")
        }
        .disabled(entry.isRunning)
        .help(CommandAction(arguments: ["delete", entry.name]).command)
      }
    } else {
      HStack(spacing: 10) {
        Button {
          isCloning = true
        } label: {
          Label(L10n.text("Clone"), systemImage: "plus.square.on.square")
        }
        .buttonStyle(.glassProminent)

        Spacer()

        Button(role: .destructive) {
          isConfirmingDelete = true
        } label: {
          Label(L10n.text("Delete Cache"), systemImage: "trash")
        }
        .help(CommandAction(arguments: ["delete", entry.name]).command)
      }
    }
  }

  private var runningCommandHint: some View {
    HStack(spacing: 14) {
      Label(L10n.text("CLI"), systemImage: "terminal")
        .font(.caption.weight(.medium))

      Text(CommandAction(arguments: ["stop", entry.name]).command)
      Text("•")
        .foregroundStyle(.tertiary)
      Text(CommandAction(arguments: ["suspend", entry.name]).command)
    }
    .font(.system(.caption, design: .monospaced))
    .foregroundStyle(.secondary)
    .textSelection(.enabled)
  }

  private var cacheSection: some View {
    GroupBox(L10n.text("OCI Image Cache")) {
      VStack(alignment: .leading, spacing: 10) {
        Label(
          L10n.text("This is a cached registry image, not a runnable VM."),
          systemImage: "shippingbox"
        )
        .font(.callout.weight(.medium))

        Text(L10n.text("Clone it to create a local VM before using Start or launch settings."))
          .font(.callout)
          .foregroundStyle(.secondary)

        Divider()

        SpecRow(
          label: L10n.text("Disk Usage"),
          value: L10n.format("%@ GB", String(entry.allocatedSizeGB))
        )
      }
      .padding(.vertical, 4)
    }
  }

  private var networkSection: some View {
    GroupBox(L10n.text("Network")) {
      VStack(alignment: .leading, spacing: 10) {
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

        if case .bridged = currentSettings.network {
          Text(L10n.text("Bridged networking uses ARP for IP lookup."))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        CommandPreview(action: ipLookupAction)
      }
      .padding(.vertical, 6)
    }
  }

  private var ipLookupAction: CommandAction {
    store.ipLookupAction(
      for: entry.name,
      settings: currentSettings,
      waitSeconds: 15
    )
  }

  private func lookUpIP() {
    isLookingUpIP = true
    Task {
      ipAddress = await store.ipAddress(
        for: entry.name,
        settings: currentSettings,
        waitSeconds: 15
      )
      isLookingUpIP = false
    }
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

          Divider()

          HStack {
            Spacer()

            Button(L10n.text("Edit Configuration…")) {
              isEditingConfig = true
            }
            .buttonStyle(.borderless)
          }
          .padding(.top, 6)
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

  private var launchSettingsSection: some View {
    GroupBox(L10n.text("Launch")) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(L10n.text("Launch Settings"))
            .font(.callout.weight(.medium))

          Spacer()

          Button(L10n.text("Edit Launch Settings…")) {
            isEditingRunSettings = true
          }
          .buttonStyle(.borderless)
        }

        let warnings = currentSettings.validate()
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

        CommandPreview(action: CommandAction(arguments: currentSettings.arguments(vmName: entry.name)))
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
