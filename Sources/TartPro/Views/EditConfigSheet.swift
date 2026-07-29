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
        Text("修改配置").font(.headline)
        Text(vmName).font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()

      Divider()

      if isRunning {
        Label("虚拟机正在运行，配置修改需要关机后才会生效。", systemImage: "info.circle")
          .font(.caption)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(10)
          .background(.quaternary.opacity(0.4))
      }

      Form {
        Section("处理器与内存") {
          HStack {
            Text("CPU")
            Slider(value: $cpuCount, in: 1...Double(maxCPU), step: 1)
            Text("\(Int(cpuCount)) 核")
              .monospacedDigit()
              .frame(width: 60, alignment: .trailing)
          }

          HStack {
            Text("内存")
            Slider(value: $memoryGB, in: 2...Double(maxMemoryGB), step: 1)
            Text("\(Int(memoryGB)) GB")
              .monospacedDigit()
              .frame(width: 60, alignment: .trailing)
          }
        }

        Section("显示") {
          HStack {
            TextField("宽", text: $width)
              .frame(width: 80)
            Text("×")
            TextField("高", text: $height)
              .frame(width: 80)
            Text("像素")
              .foregroundStyle(.secondary)
          }

          if parsedResolution == nil && (width != String(current.display.width) || height != String(current.display.height)) {
            Label("分辨率必须是正整数。", systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }

        Section("磁盘") {
          HStack {
            Slider(value: $diskSizeGB, in: Double(current.diskSizeGB)...Double(max(current.diskSizeGB * 4, 200)), step: 10)
            Text("\(Int(diskSizeGB)) GB")
              .monospacedDigit()
              .frame(width: 70, alignment: .trailing)
          }

          // tart 只允许扩大磁盘，滑块下限已经卡在当前值，这里再说明一次原因。
          Text("磁盘只能扩大，不能缩小——缩小会丢数据。当前 \(current.diskSizeGB) GB。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("标识") {
          Toggle("重新生成随机 MAC 地址", isOn: $randomMAC)
            .help("克隆出来的虚拟机如果要同时联网，需要各自不同的 MAC 地址")

          if current.os == "darwin" {
            Toggle("重新生成随机序列号", isOn: $randomSerial)
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        if hasChanges {
          Text("将修改：\(changeSummary)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("保存") {
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
    if changes.cpuCount != nil { parts.append("CPU") }
    if changes.memoryMB != nil { parts.append("内存") }
    if changes.display != nil { parts.append("分辨率") }
    if changes.diskSizeGB != nil { parts.append("磁盘") }
    if changes.randomMAC { parts.append("MAC") }
    if changes.randomSerial { parts.append("序列号") }
    return parts.joined(separator: "、")
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
      Text("重命名虚拟机").font(.headline)

      TextField("新名称", text: $newName)
        .textFieldStyle(.roundedBorder)
        .onSubmit { commitIfValid() }

      if let issue {
        Label(issue, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
      } else {
        Text("该虚拟机的启动配置会一并更名。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("重命名") { commitIfValid() }
          .keyboardShortcut(.defaultAction)
          .disabled(issue != nil || newName == currentName)
      }
    }
    .padding(20)
    .frame(width: 400)
  }

  private var issue: String? {
    if newName.isEmpty { return "名称不能为空。" }
    if newName != currentName && existingNames.contains(newName) { return "已经有同名的虚拟机了。" }
    if newName.contains("/") || newName.contains(":") { return "名称不能包含斜杠或冒号。" }
    return nil
  }

  private func commitIfValid() {
    guard issue == nil, newName != currentName else { return }
    onRename(newName)
    dismiss()
  }
}
