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
    entries.count == 1
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

/// 后台长时操作的状态条，显示在侧边栏底部。
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
              onShowLog: { expandedOperation = operation }
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
  let onShowLog: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        statusIcon

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
        } else {
          Button(L10n.text("Cancel"), action: onCancel)
            .buttonStyle(.borderless)
            .font(.caption2)
        }
      }

      // 进度百分比要靠解析 tart 的输出格式，那个格式没有稳定保证，
      // 所以这里只显示最后一行原始输出，格式变了也不会误导用户。
      if let latest = operation.latestLine {
        Text(latest)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.middle)
      }

      if case let .failed(reason) = operation.state {
        Text(reason)
          .font(.caption2)
          .foregroundStyle(.red)
          .lineLimit(2)
      }

      if !operation.recentLines.isEmpty {
        Button(L10n.text("View Log"), action: onShowLog)
          .buttonStyle(.borderless)
          .font(.caption2)
      }
    }
    .padding(6)
    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch operation.state {
    case .running:
      ProgressView().controlSize(.mini)
    case .succeeded:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
        .font(.caption)
    case .failed:
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.red)
        .font(.caption)
    case .cancelled:
      Image(systemName: "minus.circle.fill")
        .foregroundStyle(.secondary)
        .font(.caption)
    }
  }
}

/// 后台操作的完整日志。
struct OperationLogView: View {
  let operation: BackgroundOperation
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(spacing: 0) {
      Text(operation.title)
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()

      Divider()

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(Array(operation.recentLines.enumerated()), id: \.offset) { _, line in
            Text(line)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(12)
      }
      .background(.background.secondary)

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
    .frame(width: 680, height: 420)
  }
}
