import SwiftUI
import TartKit

/// 删除虚拟机的确认对话框。
///
/// 删除不可撤销，所以必须把「删的是什么、会释放多少空间、有没有正在运行」
/// 摆在用户面前，而不是一句笼统的「确定要删除吗」。
struct DeleteConfirmation: View {
  let entries: [VMListEntry]
  let runningNames: Set<String>
  let onConfirm: () -> Void

  @Environment(\.dismiss) private var dismiss
  @State private var typedConfirmation = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Label(title, systemImage: "trash")
        .font(.headline)

      VStack(alignment: .leading, spacing: 6) {
        ForEach(entries) { entry in
          HStack {
            Text(entry.name)
              .font(.system(.callout, design: .monospaced))
              .lineLimit(1)
              .truncationMode(.middle)
            if runningNames.contains(entry.name) {
              Text(L10n.text("Running"))
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
            }
            Spacer()
            Text(L10n.format("%@ GB", String(entry.allocatedSizeGB)))
              .font(.caption)
              .foregroundStyle(.secondary)
              .monospacedDigit()
          }
        }
      }
      .padding(10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))

      Text(L10n.format("About %@ GB of disk space will be freed. This cannot be undone.", String(totalSizeGB)))
        .font(.callout)

      if !runningNames.isEmpty {
        Label(
          L10n.text("One or more VMs are still running. Stop them before deleting."),
          systemImage: "exclamationmark.octagon.fill"
        )
        .font(.caption)
        .foregroundStyle(.red)
      }

      // 批量删除风险更高，要求手动输入确认，避免顺手点掉。
      if requiresTypedConfirmation {
        VStack(alignment: .leading, spacing: 4) {
          Text(L10n.text("Type DELETE to confirm:"))
            .font(.caption)
          TextField("", text: $typedConfirmation)
            .textFieldStyle(.roundedBorder)
        }
      }

      CommandPreview(action: CommandAction(arguments: ["delete"] + entries.map(\.name)))

      HStack {
        Spacer()
        Button(L10n.text("Cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(L10n.text("Delete")) {
          onConfirm()
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canDelete)
      }
    }
    .padding(20)
    .frame(width: 440)
  }

  private var title: String {
    if entries.count == 1, entries[0].source == .oci {
      return L10n.text("Delete Cached Image")
    }

    return entries.count == 1
      ? L10n.text("Delete VM")
      : L10n.format("Delete %@ VMs", String(entries.count))
  }

  private var totalSizeGB: Int {
    entries.reduce(0) { $0 + $1.allocatedSizeGB }
  }

  private var requiresTypedConfirmation: Bool {
    entries.count > 1
  }

  private var canDelete: Bool {
    // 运行中的虚拟机不能删，tart 也会拒绝。
    guard runningNames.isEmpty else { return false }
    if requiresTypedConfirmation {
      return typedConfirmation == "DELETE"
    }
    return true
  }
}

/// Unified Tart command history shown at the bottom of the sidebar.
struct OperationStatusBar: View {
  let center: OperationCenter
  @State private var expandedOperation: BackgroundOperation?

  var body: some View {
    if !center.operations.isEmpty {
      VStack(spacing: 0) {
        Divider()
        VStack(spacing: 6) {
          ForEach(center.operations) { operation in
            OperationRow(
              operation: operation,
              onCancel: { center.cancel(operation) },
              onDismiss: { center.dismiss(operation) },
              onShowDetails: { expandedOperation = operation }
            )
          }
        }
        .padding(8)
      }
      .sheet(item: $expandedOperation) { operation in
        OperationLogView(operation: operation)
      }
    }
  }
}

private struct OperationRow: View {
  let operation: BackgroundOperation
  let onCancel: () -> Void
  let onDismiss: () -> Void
  let onShowDetails: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        CommandStateBadge(state: operation.state)
        Text(operation.title)
          .font(.caption)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()

        if operation.state.isFinished {
          Button {
            onDismiss()
          } label: {
            Image(systemName: "xmark").font(.caption2)
          }
          .buttonStyle(.borderless)
        } else if operation.isCancellable {
          Button(L10n.text("Cancel"), action: onCancel)
            .buttonStyle(.borderless)
            .font(.caption2)
        }
      }

      Text(operation.action.command)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)

      if let latest = operation.latestLine {
        HStack(spacing: 5) {
          Text(latest.stream.rawValue)
            .font(.caption2.weight(.semibold))
          Text(latest.text)
            .font(.caption2)
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .foregroundStyle(latest.stream == .stderr ? .orange : .secondary)
      }

      Button(L10n.text("Details"), action: onShowDetails)
        .buttonStyle(.glass)
        .controlSize(.mini)
        .font(.caption2)
    }
    .padding(9)
    .glassEffect(.regular, in: .rect(cornerRadius: 10))
  }
}

struct OperationLogView: View {
  let operation: BackgroundOperation
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(operation.title).font(.headline)
        CommandStateBadge(state: operation.state)
        Spacer()
      }
      .padding()

      Divider()

      VStack(alignment: .leading, spacing: 12) {
        CommandPreview(action: operation.action, state: operation.state)

        HStack(spacing: 18) {
          if let pid = operation.processIdentifier {
            Text("PID \(pid)")
          }
          if let code = operation.exitCode {
            Text(L10n.format("Exit code %@", String(code)))
          }
          Text(L10n.format("Duration: %@", String(format: "%.1fs", operation.duration)))
        }
        .font(.caption)
        .foregroundStyle(.secondary)

        HStack(alignment: .top, spacing: 12) {
          outputPanel(title: "stdout", lines: operation.stdoutLines, emptyText: L10n.text("No stdout output."))
          outputPanel(title: "stderr", lines: operation.stderrLines, emptyText: L10n.text("No stderr output."))
        }
      }
      .padding(12)

      Divider()

      HStack {
        if case let .failed(reason) = operation.state {
          Text(reason)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(2)
        }
        Spacer()
        Button(L10n.text("Close")) { dismiss() }
          .keyboardShortcut(.defaultAction)
      }
      .padding()
    }
    .frame(width: 780, height: 540)
  }

  private func outputPanel(title: String, lines: [String], emptyText: String) -> some View {
    GroupBox(title) {
      ScrollView {
        if lines.isEmpty {
          Text(emptyText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
              Text(line)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, minHeight: 240, maxHeight: 280)
      .padding(.vertical, 4)
    }
    .frame(maxWidth: .infinity)
  }
}
