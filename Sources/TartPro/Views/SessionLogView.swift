import SwiftUI
import TartKit

/// 运行会话的日志窗口。
struct SessionLogView: View {
  let session: RunSession

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
      Text(session.commandLine)
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
              .foregroundStyle(line.isError ? .primary : .secondary)
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
          Text("暂无输出")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var footer: some View {
    HStack {
      Toggle("自动滚动", isOn: $autoScroll)
        .toggleStyle(.checkbox)

      if let url = session.logFileURL {
        Button("在访达中显示") {
          NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .help(url.path)
      }

      Spacer()

      // 内存中只保留最近若干行，完整内容在日志文件里。
      Text("显示最近 \(session.recentLines.count) 行")
        .font(.caption)
        .foregroundStyle(.secondary)

      Button("关闭") { dismiss() }
        .keyboardShortcut(.defaultAction)
    }
    .padding()
  }
}

private struct StateChip: View {
  let state: RunSession.State

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
    case .starting: "正在启动"
    case .running: "运行中"
    case let .exited(code): code == 0 ? "已退出" : "异常退出（\(code)）"
    case .failed: "启动失败"
    }
  }

  private var color: Color {
    switch state {
    case .starting: .orange
    case .running: .green
    case let .exited(code): code == 0 ? .secondary : .red
    case .failed: .red
    }
  }
}
