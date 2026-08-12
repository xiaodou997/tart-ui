import SwiftUI
import TartKit

/// 运行会话的日志窗口。
struct SessionLogView: View {
  let session: VMRuntimeSession

  @Environment(\.dismiss) private var dismiss
  @State private var autoScroll = true

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      logBody
      Divider()
      footer
    }
    .frame(width: 720, height: 460)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(session.vmName).font(.headline)
        StateChip(state: session.state)
        Spacer()
      }
      Text(session.equivalentCommandLine)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
    .padding()
  }

  private var logBody: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(session.recentLines) { line in
            Text(line.text)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(line.isError ? .red : line.isLifecycle ? .secondary : .primary)
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
              .id(line.id)
          }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
      }
      .background(.background.secondary)
      .onChange(of: session.recentLines.count) {
        guard autoScroll, let last = session.recentLines.last else { return }
        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
      }
      .overlay {
        if session.recentLines.isEmpty {
          Text(L10n.text("No Output Yet"))
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var footer: some View {
    HStack {
      Toggle(L10n.text("Auto-scroll"), isOn: $autoScroll)
        .toggleStyle(.checkbox)

      if let url = session.logFileURL {
        Button(L10n.text("Show in Finder")) {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .help(url.path)
      }

      Spacer()

      // 内存中只保留最近若干行，完整内容在日志文件里。
      Text(L10n.format("Showing the latest %@ lines", String(session.recentLines.count)))
        .font(.caption)
        .foregroundStyle(.secondary)

      Button(L10n.text("Close")) { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
    .padding()
  }
}

private struct StateChip: View {
  let state: VMRuntimeSession.State

  var body: some View {
    Text(label)
      .font(.caption.weight(.medium))
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .background(color.opacity(0.15), in: Capsule())
      .foregroundStyle(color)
  }

  private var label: String {
    switch state {
    case .starting: L10n.text("Starting")
    case .stopping: L10n.text("Stopping")
    case .running: L10n.text("Running")
    case .suspending: L10n.text("Suspending")
    case .suspended: L10n.text("Suspended")
    case .exited: L10n.text("Stopped")
    case .failed: L10n.text("Failed to Start")
    }
  }

  private var color: Color {
    switch state {
    case .starting, .stopping, .suspending: .orange
    case .running: .green
    case .suspended, .exited: .secondary
    case .failed: .red
    }
  }
}
