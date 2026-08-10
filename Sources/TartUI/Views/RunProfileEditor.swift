import SwiftUI
import TartKit

/// 启动配置编辑器。
///
/// `tart run` 的选项多达二十几个，平铺成一张长表单没法用。
/// 这里按「显示 / 设备 / 存储 / 网络 / 高级」分组，
/// 默认只展开常用的部分。
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
        displaySection
        deviceSection
        networkSection
        storageSection
        advancedSection
      }
      .formStyle(.grouped)

      Divider()
      footer
    }
    .frame(width: 560, height: 620)
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
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
    VStack(spacing: 8) {
      let warnings = profile.validate()
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
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      // 实时显示生成的命令，用户能直接看出每个开关的效果。
      Text("tart " + profile.arguments(vmName: vmName).joined(separator: " "))
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(3)

      HStack {
        Spacer()
        Button(L10n.text("Cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(L10n.text("Save")) {
          onSave(profile)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(profile.hasBlockingIssues || profile.name.isEmpty)
      }
    }
    .padding()
  }

  // MARK: - 分组

  private var displaySection: some View {
    Section(L10n.text("Display and Input")) {
      Toggle(L10n.text("No Graphics Window"), isOn: $profile.noGraphics)
        .help(L10n.text("Useful when accessing the VM only through SSH or VNC"))

      Toggle(L10n.text("Use Screen Sharing"), isOn: $profile.vnc)
        .help(L10n.text("Remote Login must be enabled inside the VM"))

      Toggle(L10n.text("Use Experimental VNC"), isOn: $profile.vncExperimental)
        .help(L10n.text("Available in recovery mode and during installation, but marked experimental by the upstream project"))

      Toggle(L10n.text("Send System Shortcuts to VM"), isOn: $profile.captureSystemKeys)
        .help(L10n.text("When enabled, shortcuts such as Cmd+Tab are received by the VM instead of the host"))

      Toggle(L10n.text("Disable Trackpad"), isOn: $profile.noTrackpad)
      Toggle(L10n.text("Disable Pointer"), isOn: $profile.noPointer)
      Toggle(L10n.text("Disable Keyboard"), isOn: $profile.noKeyboard)
    }
  }

  private var deviceSection: some View {
    Section(L10n.text("Devices")) {
      Toggle(L10n.text("Disable Audio"), isOn: $profile.noAudio)
      Toggle(L10n.text("Disable Clipboard Sharing"), isOn: $profile.noClipboard)

      Toggle(L10n.text("Suspendable"), isOn: $profile.suspendable)
        .help(L10n.text("Disables audio and entropy devices and uses Mac-specific input devices. Only VMs started this way can be suspended"))

      Toggle(L10n.text("Enable Nested Virtualization"), isOn: $profile.nested)
      Toggle(L10n.text("Boot into Recovery Mode"), isOn: $profile.recovery)
    }
  }

  private var networkSection: some View {
    Section(L10n.text("Network")) {
      Picker(L10n.text("Network Mode"), selection: networkKindBinding) {
        Text(L10n.text("Shared (NAT)")).tag(NetworkKind.shared)
        Text(L10n.text("Bridged")).tag(NetworkKind.bridged)
        Text("Softnet").tag(NetworkKind.softnet)
        Text(L10n.text("Host Only")).tag(NetworkKind.hostOnly)
      }

      switch profile.network {
      case .bridged:
        TextField(L10n.text("Interface"), text: bridgeInterfaceBinding, prompt: Text(L10n.text("e.g. en0 or Wi-Fi")))

      case .softnet:
        TextField(L10n.text("Allowed Networks"), text: softnetAllowBinding, prompt: Text(L10n.text("Comma-separated, e.g. 192.168.0.0/24")))
        TextField(L10n.text("Blocked Networks"), text: softnetBlockBinding, prompt: Text(L10n.text("Comma-separated")))
        TextField(L10n.text("Port Forwards"), text: softnetExposeBinding, prompt: Text(L10n.text("e.g. 2222:22,8080:80")))
          .help(L10n.text("Format: host-port:guest-port; separate multiple entries with commas"))

      case .shared, .hostOnly:
        EmptyView()
      }
    }
  }

  private var storageSection: some View {
    Section(L10n.text("Storage and Sharing")) {
      ListEditor(
        title: L10n.text("Attached Disks"),
        items: $profile.disks,
        prompt: L10n.text("path[:options], e.g. /tmp/data.img:ro")
      )

      ListEditor(
        title: L10n.text("Directory Shares"),
        items: $profile.directoryShares,
        prompt: L10n.text("[name:]path[:options], e.g. ~/src:ro")
      )
    }
  }

  private var advancedSection: some View {
    Section(L10n.text("Advanced")) {
      TextField(L10n.text("Root Disk Options"), text: optionalBinding(\.rootDiskOptions),
                prompt: Text(L10n.text("e.g. ro or caching=cached,sync=none")))

      TextField(L10n.text("Rosetta Tag"), text: optionalBinding(\.rosettaTag),
                prompt: Text(L10n.text("Only applies to Linux guests")))

      Toggle(L10n.text("Open Serial Console"), isOn: $profile.serial)

      TextField(L10n.text("External Serial Path"), text: optionalBinding(\.serialPath),
                prompt: Text(L10n.text("e.g. /dev/ttys001")))
    }
  }

  // MARK: - 绑定辅助

  private enum NetworkKind: Hashable {
    case shared, bridged, softnet, hostOnly
  }

  private var networkKindBinding: Binding<NetworkKind> {
    Binding(
      get: {
        switch profile.network {
        case .shared: .shared
        case .bridged: .bridged
        case .softnet: .softnet
        case .hostOnly: .hostOnly
        }
      },
      set: { kind in
        // 切换模式时保留同类配置，换到别的模式则重置——
        // 让桥接的接口名残留在 Softnet 配置里只会造成困惑。
        switch kind {
        case .shared: profile.network = .shared
        case .hostOnly: profile.network = .hostOnly
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
        if case let .bridged(interface) = profile.network { return interface }
        return ""
      },
      set: { profile.network = .bridged(interface: $0) }
    )
  }

  private var softnetOptions: SoftnetOptions {
    if case let .softnet(options) = profile.network { return options }
    return SoftnetOptions()
  }

  private var softnetAllowBinding: Binding<String> {
    Binding(
      get: { softnetOptions.allowedCIDRs.joined(separator: ",") },
      set: { newValue in
        var options = softnetOptions
        options.allowedCIDRs = splitList(newValue)
        profile.network = .softnet(options)
      }
    )
  }

  private var softnetBlockBinding: Binding<String> {
    Binding(
      get: { softnetOptions.blockedCIDRs.joined(separator: ",") },
      set: { newValue in
        var options = softnetOptions
        options.blockedCIDRs = splitList(newValue)
        profile.network = .softnet(options)
      }
    )
  }

  private var softnetExposeBinding: Binding<String> {
    Binding(
      get: { softnetOptions.exposedPorts.map(\.argumentValue).joined(separator: ",") },
      set: { newValue in
        var options = softnetOptions
        options.exposedPorts = splitList(newValue).compactMap(PortForward.init(parsing:))
        profile.network = .softnet(options)
      }
    )
  }

  /// 把可选字符串字段转成 TextField 能用的非可选绑定，空串等价于「未设置」。
  private func optionalBinding(_ keyPath: WritableKeyPath<RunProfile, String?>) -> Binding<String> {
    Binding(
      get: { profile[keyPath: keyPath] ?? "" },
      set: { profile[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
    )
  }

  private func splitList(_ raw: String) -> [String] {
    raw.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }
}

extension PortForward {
  /// 解析 `外部端口:内部端口` 形式。
  init?(parsing raw: String) {
    let parts = raw.split(separator: ":")
    guard parts.count == 2,
          let host = Int(parts[0].trimmingCharacters(in: .whitespaces)),
          let guest = Int(parts[1].trimmingCharacters(in: .whitespaces))
    else { return nil }
    self.init(hostPort: host, guestPort: guest)
  }
}

/// 可增删的字符串列表编辑器，用于附加磁盘和目录共享。
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
