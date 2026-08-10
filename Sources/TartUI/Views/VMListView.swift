import SwiftUI
import TartKit

struct VMListView: View {
  let store: VMStore
  @Binding var selection: VMListEntry.ID?

  var body: some View {
    List(selection: $selection) {
      if !store.localEntries.isEmpty {
        Section(L10n.text("Local VMs")) {
          ForEach(store.localEntries) { entry in
            VMRow(entry: entry)
          }
        }
      }

      if !store.ociEntries.isEmpty {
        Section(L10n.text("Image Cache")) {
          ForEach(store.ociEntries) { entry in
            VMRow(entry: entry)
          }
        }
      }
    }
    .overlay {
      if store.entries.isEmpty && !store.isLoading {
        ContentUnavailableView(
          L10n.text("No VMs Yet"),
          systemImage: "desktopcomputer",
          description: Text(L10n.text("Clone one from a registry or create a blank VM."))
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

        Text(L10n.format("%@ GB / %@ GB", String(entry.allocatedSizeGB), String(entry.diskSizeGB)))
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
    case .running: L10n.text("Running")
    case .suspended: L10n.text("Suspended")
    case .stopped: L10n.text("Stopped")
    case .unknown: L10n.text("Unknown State")
    }
  }
}
