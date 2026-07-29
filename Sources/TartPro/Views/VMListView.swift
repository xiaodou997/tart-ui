import SwiftUI
import TartKit

struct VMListView: View {
  let store: VMStore
  @Binding var selection: VMListEntry.ID?

  var body: some View {
    List(selection: $selection) {
      if !store.localEntries.isEmpty {
        Section("本地虚拟机") {
          ForEach(store.localEntries) { entry in
            VMRow(entry: entry)
          }
        }
      }

      if !store.ociEntries.isEmpty {
        Section("镜像缓存") {
          ForEach(store.ociEntries) { entry in
            VMRow(entry: entry)
          }
        }
      }
    }
    .overlay {
      if store.entries.isEmpty && !store.isLoading {
        ContentUnavailableView(
          "还没有虚拟机",
          systemImage: "desktopcomputer",
          description: Text("从镜像仓库克隆一台，或者新建一台空白虚拟机。")
        )
      }
    }
  }
}

private struct VMRow: View {
  let entry: VMListEntry

  var body: some View {
    HStack(spacing: 10) {
      StateIndicator(state: entry.state)

      VStack(alignment: .leading, spacing: 2) {
        Text(entry.name)
          .lineLimit(1)
          .truncationMode(.middle)

        Text("\(entry.allocatedSizeGB) GB / \(entry.diskSizeGB) GB")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
    .tag(entry.id)
  }
}

private struct StateIndicator: View {
  let state: VMState

  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 8, height: 8)
      .help(label)
  }

  private var color: Color {
    switch state {
    case .running: .green
    case .suspended: .orange
    case .stopped: .secondary
    case .unknown: .gray
    }
  }

  private var label: String {
    switch state {
    case .running: "运行中"
    case .suspended: "已挂起"
    case .stopped: "已停止"
    case .unknown: "状态未知"
    }
  }
}
