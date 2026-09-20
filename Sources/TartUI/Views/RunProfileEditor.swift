import AppKit
import SwiftUI
import TartKit

/// A focused editor for the launch options people change most often.
///
/// Less common Tart flags remain supported by RunProfile for compatibility, but
/// they are intentionally not presented as a large advanced configuration form.
struct RunProfileEditor: View {
  @State private var profile: RunProfile
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

        if hasLegacyAdvancedOptions {
          legacyAdvancedSection
        }
      }
      .formStyle(.grouped)

      Divider()
      footer
    }
    .frame(width: 600, height: 560)
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

      RunCommandPreview(command: profile.command(vmName: vmName))

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
        TextField(
          L10n.text("Interface"),
          text: bridgeInterfaceBinding,
          prompt: Text(L10n.text("e.g. en0 or Wi-Fi"))
        )

      case .softnet:
        Label(
          L10n.text("Softnet uses Tart defaults. Existing allow, block, and port-forward rules are preserved in the command preview."),
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

  private var legacyAdvancedSection: some View {
    Section(L10n.text("Legacy Advanced Options")) {
      Label(
        L10n.text("This profile contains advanced options from an earlier TartUI version. They are preserved and remain visible in the command preview."),
        systemImage: "clock.arrow.circlepath"
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Button(L10n.text("Remove Legacy Advanced Options")) {
        clearLegacyAdvancedOptions()
      }
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

        // The simplified editor intentionally chooses one display path. If the
        // user changes this control, an older experimental VNC setting no longer
        // shadows the visible choice.
        profile.vncExperimental = false
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
          profile.network = .bridged(interface: "")
        case .softnet:
          if case .softnet = profile.network { return }
          profile.network = .softnet(SoftnetOptions())
        }
      }
    )
  }

  private var bridgeInterfaceBinding: Binding<String> {
    Binding(
      get: {
        if case let .bridged(interface) = profile.network {
          return interface
        }
        return ""
      },
      set: {
        profile.network = .bridged(interface: $0)
      }
    )
  }

  // MARK: - Compatibility

  private var hasLegacyAdvancedOptions: Bool {
    profile.vncExperimental
      || profile.captureSystemKeys
      || profile.noTrackpad
      || profile.noPointer
      || profile.noKeyboard
      || profile.noAudio
      || profile.nested
      || profile.serial
      || !(profile.serialPath?.isEmpty ?? true)
      || !profile.disks.isEmpty
      || !(profile.rootDiskOptions?.isEmpty ?? true)
      || !(profile.rosettaTag?.isEmpty ?? true)
  }

  private func clearLegacyAdvancedOptions() {
    profile.vncExperimental = false
    profile.captureSystemKeys = false
    profile.noTrackpad = false
    profile.noPointer = false
    profile.noKeyboard = false
    profile.noAudio = false
    profile.nested = false
    profile.serial = false
    profile.serialPath = nil
    profile.disks = []
    profile.rootDiskOptions = nil
    profile.rosettaTag = nil
  }
}

/// A command preview shared by the profile editor and VM detail view.
struct RunCommandPreview: View {
  let command: String

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label(L10n.text("Command"), systemImage: "terminal")
          .font(.caption.weight(.medium))

        Spacer()

        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(command, forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help(L10n.text("Copy"))
      }

      ScrollView(.horizontal, showsIndicators: false) {
        Text(command)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
    .padding(10)
    .background {
      RoundedRectangle(cornerRadius: 8)
        .fill(Color.primary.opacity(0.04))
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
