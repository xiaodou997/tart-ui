import SwiftUI
import TartKit

/// 清理缓存或虚拟机。
///
/// tart 没有 dry-run，所以这里自己复刻它的选择逻辑做预览。
/// 预览有已知的局限（看不到 IPSW 缓存），界面上必须说清楚。
struct PruneSheet: View {
  let store: VMStore

  @Environment(\.dismiss) private var dismiss

  @State private var target: PruneTarget = .caches
  @State private var useAgeLimit = true
  @State private var olderThanDays = 30.0
  @State private var useSpaceBudget = false
  @State private var spaceBudgetGB = 100.0
  @State private var typedConfirmation = ""

  var body: some View {
    VStack(spacing: 0) {
      Text("清理磁盘空间")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()

      Divider()

      Form {
        Section("清理对象") {
          Picker("对象", selection: $target) {
            ForEach(PruneTarget.allCases, id: \.self) { item in
              Text(item.displayName).tag(item)
            }
          }
          .pickerStyle(.radioGroup)
          .labelsHidden()

          if target.isDestructive {
            // 缓存删了能重新下载，虚拟机删了就没了。
            Label(
              "这会删除真正的虚拟机，不是可以重新下载的缓存。",
              systemImage: "exclamationmark.octagon.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
          }
        }

        Section("条件") {
          Toggle("清理长期未使用的条目", isOn: $useAgeLimit)
          if useAgeLimit {
            HStack {
              Text("超过")
              Slider(value: $olderThanDays, in: 1...180, step: 1)
              Text("\(Int(olderThanDays)) 天")
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
            }
          }

          Toggle("限制总占用空间", isOn: $useSpaceBudget)
          if useSpaceBudget {
            HStack {
              Text("保留")
              Slider(value: $spaceBudgetGB, in: 10...1000, step: 10)
              Text("\(Int(spaceBudgetGB)) GB")
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            }
          }

          if !useAgeLimit && !useSpaceBudget {
            Text("至少需要指定一个条件。")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }

        Section("预计删除") {
          if plan.isEmpty {
            Text(hasCriteria ? "按当前条件，没有条目会被删除。" : "请先指定清理条件。")
              .font(.callout)
              .foregroundStyle(.secondary)
          } else {
            ForEach(plan.candidates) { candidate in
              HStack {
                Text(candidate.name)
                  .font(.system(.caption, design: .monospaced))
                  .lineLimit(1)
                  .truncationMode(.middle)
                Spacer()
                Text(relativeDate(candidate.accessedAt))
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                Text("\(candidate.sizeGB) GB")
                  .font(.caption)
                  .monospacedDigit()
              }
            }

            Text("共 \(plan.candidates.count) 项，预计释放约 \(plan.reclaimedGB) GB。")
              .font(.callout)
              .padding(.top, 4)
          }

          if plan.mayBeIncomplete && hasCriteria {
            // 这一条很重要：不能让用户以为看到的就是全部。
            Label(
              "预览不含 IPSW 安装包缓存——tart 未提供查询它的方式，实际删除的内容可能更多。",
              systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }

        if target.isDestructive && !plan.isEmpty {
          Section {
            VStack(alignment: .leading, spacing: 4) {
              Text("请输入 **删除** 以确认：")
                .font(.caption)
              TextField("", text: $typedConfirmation)
                .textFieldStyle(.roundedBorder)
            }
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Text("此操作不可撤销。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("清理") {
          Task {
            await store.prune(
              target: target,
              olderThanDays: useAgeLimit ? UInt(olderThanDays) : nil,
              spaceBudgetGB: useSpaceBudget ? UInt(spaceBudgetGB) : nil
            )
          }
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canPrune)
      }
      .padding()
    }
    .frame(width: 560, height: 620)
  }

  private var hasCriteria: Bool { useAgeLimit || useSpaceBudget }

  private var plan: PrunePlanner.Plan {
    guard hasCriteria else {
      return PrunePlanner.plan(entries: [], target: target, olderThanDays: nil, spaceBudgetGB: nil)
    }
    return store.prunePlan(
      target: target,
      olderThanDays: useAgeLimit ? UInt(olderThanDays) : nil,
      spaceBudgetGB: useSpaceBudget ? UInt(spaceBudgetGB) : nil
    )
  }

  private var canPrune: Bool {
    guard hasCriteria else { return false }
    if target.isDestructive && !plan.isEmpty {
      return typedConfirmation == "删除"
    }
    return true
  }

  private func relativeDate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}

/// 在虚拟机内执行命令（非交互式）。
struct ExecSheet: View {
  let vmName: String
  let store: VMStore

  @Environment(\.dismiss) private var dismiss

  @State private var commandText = ""
  @State private var output = ""
  @State private var errorOutput = ""
  @State private var exitCode: Int32?
  @State private var isRunning = false

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        Text("在虚拟机内执行命令").font(.headline)
        Text(vmName).font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()

      Divider()

      HStack {
        TextField("命令", text: $commandText, prompt: Text("如 sw_vers -productVersion"))
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .onSubmit { runCommand() }
          .disabled(isRunning)

        Button(isRunning ? "执行中…" : "执行") { runCommand() }
          .disabled(commandText.isEmpty || isRunning)
      }
      .padding()

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          if !output.isEmpty {
            Text(output)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
          if !errorOutput.isEmpty {
            Text(errorOutput)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(.red)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(12)
      }
      .background(.background.secondary)
      .overlay {
        if output.isEmpty && errorOutput.isEmpty && !isRunning {
          VStack(spacing: 6) {
            Text("暂无输出")
              .font(.callout)
              .foregroundStyle(.secondary)
            // 这是最常见的失败原因，提前说明省得用户困惑。
            Text("需要虚拟机内已安装并运行 tart-guest-agent。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      Divider()

      HStack {
        if let exitCode {
          Label(
            exitCode == 0 ? "执行成功" : "退出码 \(exitCode)",
            systemImage: exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill"
          )
          .font(.caption)
          .foregroundStyle(exitCode == 0 ? .green : .red)
        }
        Spacer()
        Button("关闭") { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding()
    }
    .frame(width: 640, height: 480)
  }

  private func runCommand() {
    // 按空格拆分。带引号的复杂命令交给用户自己用 sh -c 包装，
    // 在这里实现一套 shell 解析规则只会引入难以察觉的歧义。
    let parts = commandText.split(separator: " ").map(String.init)
    guard !parts.isEmpty else { return }

    isRunning = true
    output = ""
    errorOutput = ""
    exitCode = nil

    Task {
      let result = await store.exec(vmName: vmName, command: parts)
      isRunning = false

      guard let result else { return }
      output = result.stdout
      errorOutput = result.stderr
      exitCode = result.exitCode
    }
  }
}
