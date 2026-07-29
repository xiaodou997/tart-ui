import SwiftUI
import TartKit

/// 新建虚拟机。
struct CreateVMSheet: View {
  let existingNames: Set<String>
  let onCreate: (String, VMCreationSource, UInt?, DiskFormat?) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var name = ""
  @State private var kind: Kind = .macOS
  @State private var ipswSource: IPSWSource = .latest
  @State private var ipswPath = ""
  @State private var diskSizeGB = 50.0
  @State private var diskFormat: DiskFormat = .raw

  private enum Kind: Hashable {
    case macOS, linux
  }

  private enum IPSWSource: Hashable {
    case latest, custom
  }

  var body: some View {
    VStack(spacing: 0) {
      Text("新建虚拟机")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()

      Divider()

      Form {
        Section {
          TextField("名称", text: $name, prompt: Text("如 dev-machine"))

          if let issue = nameIssue {
            Label(issue, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }

        Section("系统") {
          Picker("类型", selection: $kind) {
            Text("macOS").tag(Kind.macOS)
            Text("Linux").tag(Kind.linux)
          }
          .pickerStyle(.segmented)

          if kind == .macOS {
            Picker("安装源", selection: $ipswSource) {
              Text("自动获取最新版").tag(IPSWSource.latest)
              Text("指定 IPSW").tag(IPSWSource.custom)
            }

            if ipswSource == .custom {
              HStack {
                TextField("IPSW 路径或 URL", text: $ipswPath)
                Button("选择…") { chooseIPSW() }
              }
            } else {
              Text("tart 会自动下载最新支持的 macOS 安装包，约 15 GB。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } else {
            Text("将创建空白的 Linux 虚拟机，需要自行挂载安装介质后再启动。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Section("磁盘") {
          HStack {
            Slider(value: $diskSizeGB, in: 20...500, step: 10)
            Text("\(Int(diskSizeGB)) GB")
              .monospacedDigit()
              .frame(width: 70, alignment: .trailing)
          }

          Picker("格式", selection: $diskFormat) {
            ForEach(DiskFormat.allCases, id: \.self) { format in
              Text(format.displayName).tag(format)
            }
          }

          if diskFormat == .asif && !isTahoeOrLater {
            // ASIF 需要 macOS 26，低版本上创建会失败。
            Label("当前系统版本不支持 ASIF 格式，创建会失败。", systemImage: "exclamationmark.octagon.fill")
              .font(.caption)
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("创建") {
          onCreate(name, source, UInt(diskSizeGB), diskFormat)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canCreate)
      }
      .padding()
    }
    .frame(width: 520, height: 520)
  }

  private var source: VMCreationSource {
    switch kind {
    case .linux: .linux
    case .macOS: ipswSource == .latest ? .latestMacOS : .macOSFromIPSW(ipswPath)
    }
  }

  private var nameIssue: String? {
    guard !name.isEmpty else { return nil }
    if existingNames.contains(name) {
      return "已经有同名的虚拟机了。"
    }
    if name.contains("/") || name.contains(":") {
      // 这两个字符在 OCI 引用里有特殊含义，用作本地名字会造成歧义。
      return "名称不能包含斜杠或冒号。"
    }
    return nil
  }

  private var canCreate: Bool {
    guard !name.isEmpty, nameIssue == nil else { return false }
    if diskFormat == .asif && !isTahoeOrLater { return false }
    if kind == .macOS && ipswSource == .custom && ipswPath.isEmpty { return false }
    return true
  }

  private var isTahoeOrLater: Bool {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(
      OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
    )
  }

  private func chooseIPSW() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.init(filenameExtension: "ipsw") ?? .data]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false

    if panel.runModal() == .OK, let url = panel.url {
      ipswPath = url.path
    }
  }
}

/// 克隆虚拟机或镜像。
struct CloneVMSheet: View {
  let sourceName: String
  let existingNames: Set<String>
  let onClone: (String, String, Bool, UInt?) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var newName: String
  @State private var showAdvanced = false
  @State private var insecure = false
  @State private var concurrency = 4.0

  init(
    sourceName: String,
    existingNames: Set<String>,
    onClone: @escaping (String, String, Bool, UInt?) -> Void
  ) {
    self.sourceName = sourceName
    self.existingNames = existingNames
    self.onClone = onClone
    // 从镜像引用里推一个合理的默认名字，省去用户手敲。
    _newName = State(initialValue: Self.suggestName(from: sourceName, existing: existingNames))
  }

  var body: some View {
    VStack(spacing: 0) {
      Text("克隆虚拟机")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()

      Divider()

      Form {
        Section("来源") {
          Text(sourceName)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
        }

        Section("新名称") {
          TextField("名称", text: $newName)

          if existingNames.contains(newName) {
            Label("已经有同名的虚拟机了。", systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }

        Section {
          DisclosureGroup("高级选项", isExpanded: $showAdvanced) {
            HStack {
              Text("网络并发数")
              Slider(value: $concurrency, in: 1...16, step: 1)
              Text("\(Int(concurrency))")
                .monospacedDigit()
                .frame(width: 30)
            }
            .help("从远程仓库拉取时的并发连接数")

            Toggle("允许不安全的 HTTP 连接", isOn: $insecure)
              .help("仅在访问内网的私有仓库时才需要")
          }
        } footer: {
          if isRemoteSource {
            Text("从远程仓库克隆需要下载完整镜像，可能需要较长时间。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("克隆") {
          onClone(sourceName, newName, insecure, UInt(concurrency))
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(newName.isEmpty || existingNames.contains(newName))
      }
      .padding()
    }
    .frame(width: 520, height: 420)
  }

  private var isRemoteSource: Bool {
    sourceName.contains("/")
  }

  /// 从 `ghcr.io/org/macos-sequoia-base:latest` 推出 `macos-sequoia-base`。
  private static func suggestName(from source: String, existing: Set<String>) -> String {
    let lastComponent = source.split(separator: "/").last.map(String.init) ?? source
    let withoutTag = lastComponent.split(separator: ":").first.map(String.init) ?? lastComponent
    let base = withoutTag.isEmpty ? "clone" : withoutTag

    guard existing.contains(base) else { return base }

    // 撞名了就加序号，省得用户自己想。
    for index in 2...99 where !existing.contains("\(base)-\(index)") {
      return "\(base)-\(index)"
    }
    return base
  }
}
