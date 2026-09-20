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
      Text(L10n.text("Prune Disk Space"))
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()

      Divider()

      Form {
        Section(L10n.text("Prune Target")) {
          Picker(L10n.text("Target"), selection: $target) {
            ForEach(PruneTarget.allCases, id: \.self) { item in
              Text(L10n.text(item.displayName)).tag(item)
            }
          }
          .pickerStyle(.radioGroup)
          .labelsHidden()

          if target.isDestructive {
            // 缓存删了能重新下载，虚拟机删了就没了。
            Label(
              L10n.text("This deletes actual VMs, not re-downloadable caches."),
              systemImage: "exclamationmark.octagon.fill"
            )
            .font(.caption)
            .foregroundStyle(.red)
          }
        }

        Section(L10n.text("Criteria")) {
          Toggle(L10n.text("Remove unused entries"), isOn: $useAgeLimit)
          if useAgeLimit {
            HStack {
              Text(L10n.text("Older than"))
              Slider(value: $olderThanDays, in: 1...180, step: 1)
              Text(L10n.format("%@ days", String(Int(olderThanDays))))
                .monospacedDigit()
                .frame(width: 60, alignment: .trailing)
            }
          }

          Toggle(L10n.text("Limit total disk usage"), isOn: $useSpaceBudget)
          if useSpaceBudget {
            HStack {
              Text(L10n.text("Keep"))
              Slider(value: $spaceBudgetGB, in: 10...1000, step: 10)
              Text(L10n.format("%@ GB", String(Int(spaceBudgetGB))))
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
            }
          }

          if !useAgeLimit && !useSpaceBudget {
            Text(L10n.text("Select at least one criterion."))
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }

        Section(L10n.text("Estimated Deletions")) {
          if plan.isEmpty {
            Text(L10n.text(hasCriteria ? "No entries match the current criteria." : "Select at least one criterion first."))
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

            Text(L10n.format("%@ entries; approximately %@ GB will be reclaimed.", String(plan.candidates.count), String(plan.reclaimedGB)))
              .font(.callout)
              .padding(.top, 4)
          }

          if plan.mayBeIncomplete && hasCriteria {
            // 这一条很重要：不能让用户以为看到的就是全部。
            Label(
              L10n.text("The preview excludes IPSW installer caches because tart cannot list them. The actual cleanup may remove more."),
              systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }

        if target.isDestructive && !plan.isEmpty {
          Section {
            VStack(alignment: .leading, spacing: 4) {
              Text(L10n.text("Type DELETE to confirm:"))
                .font(.caption)
              TextField("", text: $typedConfirmation)
                .textFieldStyle(.roundedBorder)
            }
          }
        }
      }
      .formStyle(.grouped)

      if hasCriteria {
        CommandPreview(action: pruneAction)
          .padding(.horizontal)
          .padding(.bottom, 12)
      }

      Divider()

      HStack {
        Text(L10n.text("This operation cannot be undone."))
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(L10n.text("Cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(L10n.text("Prune")) {
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
    .frame(width: 580, height: 680)
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

  private var pruneAction: CommandAction {
    var arguments = ["prune", "--entries", target.rawValue]
    if useAgeLimit {
      arguments += ["--older-than", String(Int(olderThanDays))]
    }
    if useSpaceBudget {
      arguments += ["--space-budget", String(Int(spaceBudgetGB))]
    }
    return CommandAction(arguments: arguments)
  }

  private var canPrune: Bool {
    guard hasCriteria else { return false }
    if target.isDestructive && !plan.isEmpty {
      return typedConfirmation == "DELETE"
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
        Text(L10n.text("Run a Command in the VM")).font(.headline)
        Text(vmName).font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()

      Divider()

      HStack {
        TextField(L10n.text("Command"), text: $commandText, prompt: Text(L10n.text("e.g. sw_vers -productVersion")))
          .textFieldStyle(.roundedBorder)
          .font(.system(.body, design: .monospaced))
          .onSubmit { runCommand() }
          .disabled(isRunning)

        Button(isRunning ? L10n.text("Running…") : L10n.text("Run")) { runCommand() }
          .disabled(commandText.isEmpty || isRunning)
      }
      .padding()

      if !commandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        CommandPreview(action: execAction)
          .padding(.horizontal)
          .padding(.bottom, 10)
      }

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
            Text(L10n.text("No Output Yet"))
              .font(.callout)
              .foregroundStyle(.secondary)
            // 这是最常见的失败原因，提前说明省得用户困惑。
            Text(L10n.text("The VM must have tart-guest-agent installed and running."))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }

      Divider()

      HStack {
        if let exitCode {
          Label(
            exitCode == 0 ? L10n.text("Command Succeeded") : L10n.format("Exit code %@", String(exitCode)),
            systemImage: exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill"
          )
          .font(.caption)
          .foregroundStyle(exitCode == 0 ? .green : .red)
        }
        Spacer()
        Button(L10n.text("Close")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding()
    }
    .frame(width: 640, height: 480)
  }

  private var execAction: CommandAction {
    let parts = commandText.split(separator: " ").map(String.init)
    return CommandAction(arguments: ["exec", vmName] + parts)
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
