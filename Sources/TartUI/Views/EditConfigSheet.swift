import SwiftUI
import TartKit

/// 修改虚拟机的硬件配置。
struct EditConfigSheet: View {
  let vmName: String
  let current: VMDetails
  let isRunning: Bool
  let onSave: (ConfigChanges) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var cpuCount: Double
  @State private var memoryGB: Double
  @State private var width: String
  @State private var height: String
  @State private var diskSizeGB: Double
  @State private var randomMAC = false
  @State private var randomSerial = false

  init(vmName: String, current: VMDetails, isRunning: Bool, onSave: @escaping (ConfigChanges) -> Void) {
    self.vmName = vmName
    self.current = current
    self.isRunning = isRunning
    self.onSave = onSave

    _cpuCount = State(initialValue: Double(current.cpuCount))
    _memoryGB = State(initialValue: current.memoryGB)
    _width = State(initialValue: String(current.display.width))
    _height = State(initialValue: String(current.display.height))
    _diskSizeGB = State(initialValue: Double(current.diskSizeGB))
  }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.text("Edit Configuration")).font(.headline)
        Text(vmName).font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()

      Divider()

      if isRunning {
        Label(L10n.text("The VM is running. Configuration changes take effect after shutdown."), systemImage: "info.circle")
          .font(.caption)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .background(.quaternary.opacity(0.4))
      }

      Form {
        Section(L10n.text("CPU and Memory")) {
          HStack {
            Text("CPU")
            Slider(value: $cpuCount, in: 1...Double(maxCPU), step: 1)
            Text(L10n.format("%@ cores", String(Int(cpuCount))))
              .monospacedDigit()
              .frame(width: 60, alignment: .trailing)
          }

          HStack {
            Text(L10n.text("Memory"))
            Slider(value: $memoryGB, in: 2...Double(maxMemoryGB), step: 1)
            Text(L10n.format("%@ GB", String(Int(memoryGB))))
              .monospacedDigit()
              .frame(width: 60, alignment: .trailing)
          }
        }

        Section(L10n.text("Display")) {
          HStack {
            TextField(L10n.text("Width"), text: $width)
              .frame(width: 80)
            Text("×")
            TextField(L10n.text("Height"), text: $height)
              .frame(width: 80)
            Text(L10n.text("pixels"))
              .foregroundStyle(.secondary)
          }

          if parsedResolution == nil && (width != String(current.display.width) || height != String(current.display.height)) {
            Label(L10n.text("Resolution must be positive integers."), systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }

        Section(L10n.text("Disk")) {
          HStack {
            Slider(value: $diskSizeGB, in: Double(current.diskSizeGB)...Double(max(current.diskSizeGB * 4, 200)), step: 10)
            Text(L10n.format("%@ GB", String(Int(diskSizeGB))))
              .monospacedDigit()
              .frame(width: 70, alignment: .trailing)
          }

          // tart 只允许扩大磁盘，滑块下限已经卡在当前值，这里再说明一次原因。
          Text(L10n.format("The disk can only grow, not shrink; shrinking can cause data loss. Current size: %@ GB.", String(current.diskSizeGB)))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section(L10n.text("Identity")) {
          Toggle(L10n.text("Generate a Random MAC Address"), isOn: $randomMAC)
            .help(L10n.text("Cloned VMs need different MAC addresses if they will run on the same network"))

          if current.os == "darwin" {
            Toggle(L10n.text("Generate a Random Serial Number"), isOn: $randomSerial)
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        if hasChanges {
          Text(L10n.format("Changes: %@", changeSummary))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button(L10n.text("Cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(L10n.text("Save")) {
          onSave(changes)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!hasChanges || !isValid)
      }
      .padding()
    }
    .frame(width: 520, height: 580)
  }

  // MARK: - 变更计算

  /// 只提交真正改动过的项，避免无谓地触碰其他配置。
  private var changes: ConfigChanges {
    ConfigChanges(
      cpuCount: Int(cpuCount) != current.cpuCount ? Int(cpuCount) : nil,
      memoryMB: Int(memoryGB * 1024) != current.memoryMB ? Int(memoryGB * 1024) : nil,
      display: parsedResolution != current.display ? parsedResolution : nil,
      diskSizeGB: Int(diskSizeGB) != current.diskSizeGB ? Int(diskSizeGB) : nil,
      randomMAC: randomMAC,
      randomSerial: randomSerial
    )
  }

  private var parsedResolution: DisplayResolution? {
    guard let w = Int(width), let h = Int(height), w > 0, h > 0 else { return nil }
    return DisplayResolution(width: w, height: h)
  }

  private var hasChanges: Bool { changes.isEmpty == false }

  private var isValid: Bool {
    // 分辨率输入框有内容但解析不出来时不允许保存。
    if parsedResolution == nil { return false }
    return DiskResizeValidation.isValid(currentGB: current.diskSizeGB, targetGB: Int(diskSizeGB))
  }

  private var changeSummary: String {
    var parts: [String] = []
    if changes.cpuCount != nil { parts.append(L10n.text("CPU")) }
    if changes.memoryMB != nil { parts.append(L10n.text("Memory")) }
    if changes.display != nil { parts.append(L10n.text("Resolution")) }
    if changes.diskSizeGB != nil { parts.append(L10n.text("Disk")) }
    if changes.randomMAC { parts.append("MAC") }
    if changes.randomSerial { parts.append(L10n.text("Serial Number")) }
    return parts.joined(separator: ", ")
  }

  private var maxCPU: Int {
    ProcessInfo.processInfo.processorCount
  }

  private var maxMemoryGB: Int {
    // 留一部分给宿主机，不允许把全部内存都分给虚拟机。
    max(4, Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824) - 4)
  }
}

/// 一次配置修改中实际改动的项。
struct ConfigChanges {
  var cpuCount: Int?
  var memoryMB: Int?
  var display: DisplayResolution?
  var diskSizeGB: Int?
  var randomMAC: Bool
  var randomSerial: Bool

  var isEmpty: Bool {
    cpuCount == nil && memoryMB == nil && display == nil
      && diskSizeGB == nil && !randomMAC && !randomSerial
  }
}

/// 重命名虚拟机。
struct RenameSheet: View {
  let currentName: String
  let existingNames: Set<String>
  let onRename: (String) -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var newName: String

  init(currentName: String, existingNames: Set<String>, onRename: @escaping (String) -> Void) {
    self.currentName = currentName
    self.existingNames = existingNames
    self.onRename = onRename
    _newName = State(initialValue: currentName)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(L10n.text("Rename VM")).font(.headline)

      TextField(L10n.text("New Name"), text: $newName)
        .textFieldStyle(.roundedBorder)
        .onSubmit { commitIfValid() }

      if let issue {
        Label(L10n.text(issue), systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      } else {
        Text(L10n.text("The VM's run profiles will be renamed as well."))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button(L10n.text("Cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(L10n.text("Rename")) { commitIfValid() }
          .keyboardShortcut(.defaultAction)
          .disabled(issue != nil || newName == currentName)
      }
    }
    .padding(20)
    .frame(width: 400)
  }

  private var issue: String? {
    if newName.isEmpty { return "Name cannot be empty." }
    if newName != currentName && existingNames.contains(newName) { return "A VM with this name already exists." }
    if newName.contains("/") || newName.contains(":") { return "Names cannot contain slash or colon." }
    return nil
  }

  private func commitIfValid() {
    guard issue == nil, newName != currentName else { return }
    onRename(newName)
    dismiss()
  }
}
