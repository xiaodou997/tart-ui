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
