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
        TextField("配置名称", text: $profile.name)
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
              Text(warning.message).font(.caption)
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
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("保存") {
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
    Section("显示与输入") {
      Toggle("不打开图形窗口", isOn: $profile.noGraphics)
        .help("适合只通过 SSH 或 VNC 访问的场景")

      Toggle("使用屏幕共享", isOn: $profile.vnc)
        .help("需要在虚拟机内开启「远程登录」")

      Toggle("使用实验性 VNC", isOn: $profile.vncExperimental)
        .help("恢复模式和系统安装过程中也可用，但官方标注为实验性")

      Toggle("系统快捷键发送给虚拟机", isOn: $profile.captureSystemKeys)
        .help("启用后 Cmd+Tab 等快捷键会被虚拟机接收，而不是宿主机")

      Toggle("禁用触控板", isOn: $profile.noTrackpad)
      Toggle("禁用指针", isOn: $profile.noPointer)
      Toggle("禁用键盘", isOn: $profile.noKeyboard)
    }
  }

  private var deviceSection: some View {
    Section("设备") {
      Toggle("禁用音频", isOn: $profile.noAudio)
      Toggle("禁用剪贴板共享", isOn: $profile.noClipboard)

      Toggle("可挂起", isOn: $profile.suspendable)
        .help("关闭音频和熵设备，换用 Mac 专用输入设备。只有这样启动的虚拟机才能被挂起")

      Toggle("启用嵌套虚拟化", isOn: $profile.nested)
      Toggle("进入恢复模式", isOn: $profile.recovery)
    }
  }

  private var networkSection: some View {
    Section("网络") {
      Picker("网络模式", selection: networkKindBinding) {
        Text("共享（NAT）").tag(NetworkKind.shared)
        Text("桥接").tag(NetworkKind.bridged)
        Text("Softnet").tag(NetworkKind.softnet)
        Text("仅宿主机").tag(NetworkKind.hostOnly)
      }

      switch profile.network {
      case .bridged:
        TextField("接口名", text: bridgeInterfaceBinding, prompt: Text("如 en0 或 Wi-Fi"))

      case .softnet:
        TextField("放行网段", text: softnetAllowBinding, prompt: Text("逗号分隔，如 192.168.0.0/24"))
        TextField("阻止网段", text: softnetBlockBinding, prompt: Text("逗号分隔"))
        TextField("端口转发", text: softnetExposeBinding, prompt: Text("如 2222:22,8080:80"))
          .help("格式为「宿主机端口:虚拟机端口」，多条用逗号分隔")

      case .shared, .hostOnly:
        EmptyView()
      }
    }
  }

  private var storageSection: some View {
    Section("存储与共享") {
      ListEditor(
        title: "附加磁盘",
        items: $profile.disks,
        prompt: "路径[:选项]，如 /tmp/data.img:ro"
      )

      ListEditor(
        title: "目录共享",
        items: $profile.directoryShares,
        prompt: "[名称:]路径[:选项]，如 ~/src:ro"
      )
    }
  }

  private var advancedSection: some View {
    Section("高级") {
      TextField("根磁盘选项", text: optionalBinding(\.rootDiskOptions),
                prompt: Text("如 ro 或 caching=cached,sync=none"))

      TextField("Rosetta 标签", text: optionalBinding(\.rosettaTag),
                prompt: Text("仅对 Linux 客户机有效"))

      Toggle("打开串口控制台", isOn: $profile.serial)

      TextField("外部串口路径", text: optionalBinding(\.serialPath),
                prompt: Text("如 /dev/ttys001"))
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
