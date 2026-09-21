import AppKit
import SwiftUI
import TartKit

/// A focused editor for the launch options TartUI currently supports.
///
/// RunProfile mirrors this visible surface so generated Tart commands remain
/// predictable from the controls shown in the app.
struct RunProfileEditor: View {
  @State private var profile: RunProfile
  @State private var availableBridgeInterfaces: [BridgedNetworkInterfaceInfo] = []
  let vmName: String
  let onSave: (RunProfile) -> Void

  @Environment(\.dismiss) private var dismiss

  init(profile: RunProfile, vmName: String, onSave: @escaping (RunProfile) -> Void) {
    self._profile = State(initialValue: profile)
    self.vmName = vmName
    self.onSave = onSave
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()

      Form {
        launchSection
        networkSection
        sharingSection
      }
      .formStyle(.grouped)

      Divider()
      footer
    }
    .frame(width: 620, height: 600)
    .onAppear {
      refreshBridgeInterfaces()
    }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        TextField(L10n.text("Profile Name"), text: $profile.name)
          .textFieldStyle(.plain)
          .font(.headline)

        Text(vmName)
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer()
    }
    .padding()
  }

  private var footer: some View {
    VStack(spacing: 10) {
      let warnings = profile.validate()
      if !warnings.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(warnings) { warning in
            Label {
              Text(L10n.text(warning.message))
                .font(.caption)
            } icon: {
              Image(systemName: warning.isBlocking
                ? "exclamationmark.octagon.fill"
                : "exclamationmark.triangle.fill")
                .foregroundStyle(warning.isBlocking ? .red : .orange)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      CommandPreview(action: CommandAction(arguments: profile.arguments(vmName: vmName)))

      HStack {
        Spacer()

        Button(L10n.text("Cancel")) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)

        Button(L10n.text("Save")) {
          onSave(profile)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(profile.hasBlockingIssues || profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding()
  }

  // MARK: - Common options

  private var launchSection: some View {
    Section(L10n.text("Launch")) {
      Picker(L10n.text("Display"), selection: displayModeBinding) {
        Text(L10n.text("Window")).tag(DisplayMode.window)
        Text(L10n.text("Headless")).tag(DisplayMode.headless)
        Text(L10n.text("Screen Sharing")).tag(DisplayMode.screenSharing)
      }
      .pickerStyle(.segmented)

      Toggle(L10n.text("Allow Suspend"), isOn: $profile.suspendable)
        .help(L10n.text("Only VMs started with Suspendable can be suspended"))

      Toggle(L10n.text("Boot into Recovery Mode"), isOn: $profile.recovery)

      Toggle(L10n.text("Disable Clipboard Sharing"), isOn: $profile.noClipboard)
    }
  }

  private var networkSection: some View {
    Section(L10n.text("Network")) {
      Picker(L10n.text("Network Mode"), selection: networkKindBinding) {
        Text(L10n.text("Shared (NAT)")).tag(NetworkKind.shared)
        Text(L10n.text("Bridged")).tag(NetworkKind.bridged)
        Text(L10n.text("Host Only")).tag(NetworkKind.hostOnly)
        Text("Softnet").tag(NetworkKind.softnet)
      }

      switch profile.network {
      case .bridged:
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              Text(L10n.text("Network Adapters"))
                .font(.subheadline.weight(.medium))
              Text(L10n.text("Bridged networking connects the VM directly to one or more host network interfaces."))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
              refreshBridgeInterfaces()
            } label: {
              Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("Refresh Network Interfaces"))
          }

          if availableBridgeInterfaces.isEmpty {
            Label(
              L10n.text("No bridgeable network interfaces were found on this Mac."),
              systemImage: "network.slash"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }

          ForEach(bridgeInterfaceValues.indices, id: \.self) { index in
            HStack(spacing: 8) {
              Picker(
                "\(L10n.text("Adapter")) \(index + 1)",
                selection: bridgeInterfaceBinding(at: index)
              ) {
                ForEach(bridgeChoices(for: index)) { choice in
                  Text(choice.label).tag(choice.value)
                }
              }

              Button {
                removeBridgedInterface(at: index)
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.borderless)
              .help(L10n.text("Remove Network Adapter"))
            }
          }

          Button {
            addBridgedInterface()
          } label: {
            Label(L10n.text("Add Network Adapter"), systemImage: "plus")
          }
          .disabled(firstUnusedBridgeInterface == nil)
        }

      case .softnet:
        Label(
          L10n.text("Softnet uses Tart defaults."),
          systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)

      case .shared, .hostOnly:
        EmptyView()
      }
    }
  }

  private var sharingSection: some View {
    Section(L10n.text("Directory Sharing")) {
      ListEditor(
        title: L10n.text("Directory Shares"),
        items: $profile.directoryShares,
        prompt: L10n.text("[name:]path[:options], e.g. ~/src:ro")
      )
    }
  }

  // MARK: - Bindings

  private enum DisplayMode: Hashable {
    case window
    case headless
    case screenSharing
  }

  private var displayModeBinding: Binding<DisplayMode> {
    Binding(
      get: {
        if profile.vnc { return .screenSharing }
        if profile.noGraphics { return .headless }
        return .window
      },
      set: { mode in
        profile.noGraphics = mode == .headless
        profile.vnc = mode == .screenSharing
      }
    )
  }

  private enum NetworkKind: Hashable {
    case shared
    case bridged
    case hostOnly
    case softnet
  }

  private var networkKindBinding: Binding<NetworkKind> {
    Binding(
      get: {
        switch profile.network {
        case .shared: .shared
        case .bridged: .bridged
        case .hostOnly: .hostOnly
        case .softnet: .softnet
        }
      },
      set: { kind in
        switch kind {
        case .shared:
          profile.network = .shared
        case .hostOnly:
          profile.network = .hostOnly
        case .bridged:
          if case .bridged = profile.network { return }
          profile.network = .bridged(interfaces: [])
        case .softnet:
          if case .softnet = profile.network { return }
          profile.network = .softnet
        }
      }
    )
  }

  private struct BridgeChoice: Identifiable {
    let value: String
    let label: String

    var id: String { value }
  }

  private var bridgeInterfaceValues: [String] {
    guard case let .bridged(interfaces) = profile.network else { return [] }
    return interfaces
  }

  private var firstUnusedBridgeInterface: BridgedNetworkInterfaceInfo? {
    let selected = Set(bridgeInterfaceValues)
    return availableBridgeInterfaces.first { !selected.contains($0.identifier) }
  }

  private func bridgeChoices(for index: Int) -> [BridgeChoice] {
    let values = bridgeInterfaceValues
    guard values.indices.contains(index) else { return [] }

    let current = values[index]
    let usedElsewhere = Set(
      values.enumerated().compactMap { offset, value in
        offset == index ? nil : value
      }
    )

    var choices = availableBridgeInterfaces
      .filter { !usedElsewhere.contains($0.identifier) }
      .map { BridgeChoice(value: $0.identifier, label: $0.displayLabel) }

    if !current.isEmpty && !choices.contains(where: { $0.value == current }) {
      choices.insert(
        BridgeChoice(
          value: current,
          label: L10n.format("%@ (Unavailable)", current)
        ),
        at: 0
      )
    }

    return choices
  }

  private func bridgeInterfaceBinding(at index: Int) -> Binding<String> {
    Binding(
      get: {
        let values = bridgeInterfaceValues
        return values.indices.contains(index) ? values[index] : ""
      },
      set: { newValue in
        guard case var .bridged(interfaces) = profile.network,
              interfaces.indices.contains(index)
        else {
          return
        }

        interfaces[index] = newValue
        profile.network = .bridged(interfaces: interfaces)
      }
    )
  }

  private func addBridgedInterface() {
    guard let next = firstUnusedBridgeInterface,
          case var .bridged(interfaces) = profile.network
    else {
      return
    }

    interfaces.append(next.identifier)
    profile.network = .bridged(interfaces: interfaces)
  }

  private func removeBridgedInterface(at index: Int) {
    guard case var .bridged(interfaces) = profile.network,
          interfaces.indices.contains(index)
    else {
      return
    }

    interfaces.remove(at: index)
    profile.network = .bridged(interfaces: interfaces)
  }

  private func refreshBridgeInterfaces() {
    availableBridgeInterfaces = BridgedNetworkInterfaceCatalog.available()
  }
}

/// Shared CLI transparency surface used before and after execution.
struct CommandPreview: View {
  let action: CommandAction
  var state: BackgroundOperation.State? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label(L10n.text("Command"), systemImage: "terminal")
          .font(.caption.weight(.medium))

        if let state {
          CommandStateBadge(state: state)
        }

        Spacer()

        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(action.command, forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(L10n.text("Copy"))
      }

      ScrollView(.horizontal, showsIndicators: false) {
        Text(action.command)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
    .padding(12)
    .glassEffect(.regular, in: .rect(cornerRadius: 12))
  }
}

struct CommandStateBadge: View {
  let state: BackgroundOperation.State

  var body: some View {
    Text(label)
      .font(.caption2.weight(.medium))
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(color.opacity(0.14), in: Capsule())
      .foregroundStyle(color)
  }

  private var label: String {
    switch state {
    case .running: L10n.text("Running")
    case .succeeded: L10n.text("Succeeded")
    case .failed: L10n.text("Failed")
    case .cancelled: L10n.text("Cancelled")
    }
  }

  private var color: Color {
    switch state {
    case .running: .blue
    case .succeeded: .green
    case .failed: .red
    case .cancelled: .secondary
    }
  }
}

/// Small list editor used for directory-share arguments.
private struct ListEditor: View {
  let title: String
  @Binding var items: [String]
  let prompt: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title)

        Spacer()

        Button {
          items.append("")
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
      }

      ForEach(items.indices, id: \.self) { index in
        HStack {
          TextField("", text: $items[index], prompt: Text(prompt))
            .textFieldStyle(.roundedBorder)

          Button {
            items.remove(at: index)
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
        }
      }
    }
  }
}
