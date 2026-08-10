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
      Text(L10n.text("Create VM"))
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()

      Divider()

      Form {
        Section {
          TextField(L10n.text("Name"), text: $name, prompt: Text(L10n.text("e.g. dev-machine")))

          if let issue = nameIssue {
            Label(L10n.text(issue), systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }

        Section(L10n.text("System")) {
          Picker(L10n.text("Type"), selection: $kind) {
            Text("macOS").tag(Kind.macOS)
            Text("Linux").tag(Kind.linux)
          }
          .pickerStyle(.segmented)

          if kind == .macOS {
            Picker(L10n.text("Installation Source"), selection: $ipswSource) {
              Text(L10n.text("Download Latest")) .tag(IPSWSource.latest)
              Text(L10n.text("Specify IPSW")).tag(IPSWSource.custom)
            }

            if ipswSource == .custom {
              HStack {
                TextField(L10n.text("IPSW Path or URL"), text: $ipswPath)
                Button(L10n.text("Choose…")) { chooseIPSW() }
              }
            } else {
              Text(L10n.text("tart will download the latest supported macOS installer, about 15 GB."))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } else {
            Text(L10n.text("This creates a blank Linux VM. Attach installation media before starting it."))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Section(L10n.text("Disk")) {
          HStack {
            Slider(value: $diskSizeGB, in: 20...500, step: 10)
            Text(L10n.format("%@ GB", String(Int(diskSizeGB))))
              .monospacedDigit()
              .frame(width: 70, alignment: .trailing)
          }

          Picker(L10n.text("Format"), selection: $diskFormat) {
            ForEach(DiskFormat.allCases, id: \.self) { format in
              Text(L10n.text(format.displayName)).tag(format)
            }
          }

          if diskFormat == .asif && !isTahoeOrLater {
            // ASIF 需要 macOS 26，低版本上创建会失败。
            Label(L10n.text("This macOS version does not support ASIF; creation will fail."), systemImage: "exclamationmark.octagon.fill")
              .font(.caption)
              .foregroundStyle(.red)
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Spacer()
        Button(L10n.text("Cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(L10n.text("Create")) {
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
      return "A VM with this name already exists."
    }
    if name.contains("/") || name.contains(":") {
      // 这两个字符在 OCI 引用里有特殊含义，用作本地名字会造成歧义。
      return "Names cannot contain slash or colon."
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
      Text(L10n.text("Clone VM"))
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()

      Divider()

      Form {
        Section(L10n.text("Source")) {
          Text(sourceName)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
        }

        Section(L10n.text("New Name")) {
          TextField(L10n.text("Name"), text: $newName)

          if existingNames.contains(newName) {
            Label(L10n.text("A VM with this name already exists."), systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }

        Section {
          DisclosureGroup(L10n.text("Advanced Options"), isExpanded: $showAdvanced) {
            HStack {
              Text(L10n.text("Network Concurrency"))
              Slider(value: $concurrency, in: 1...16, step: 1)
              Text("\(Int(concurrency))")
                .monospacedDigit()
                .frame(width: 30)
            }
            .help(L10n.text("Number of concurrent connections used when pulling from a registry"))

            Toggle(L10n.text("Allow Insecure HTTP"), isOn: $insecure)
              .help(L10n.text("Only needed for private registries on an internal network"))
          }
        } footer: {
          if isRemoteSource {
            Text(L10n.text("Cloning from a registry downloads the complete image and may take a while."))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Spacer()
        Button(L10n.text("Cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(L10n.text("Clone")) {
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
