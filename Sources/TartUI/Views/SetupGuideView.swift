import AppKit
import SwiftUI

/// First-run recovery screen shown when no usable tart executable can be found.
struct SetupGuideView: View {
  let message: String
  let isInstalling: Bool
  let onInstall: () -> Void
  let onChooseExisting: (String) -> Void
  let onRetry: () -> Void

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "shippingbox.and.arrow.backward")
        .font(.system(size: 42))
        .foregroundStyle(Color.accentColor)

      VStack(spacing: 6) {
        Text(L10n.text("Tart Required"))
          .font(.title2.weight(.semibold))

        Text(L10n.text("TartUI is a graphical interface for Tart. Install the official runtime or choose an existing Tart executable to continue."))
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      if !message.isEmpty {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
          .padding(.horizontal, 12)
      }

      VStack(spacing: 10) {
        Button {
          onInstall()
        } label: {
          if isInstalling {
            ProgressView()
              .controlSize(.small)
            Text(L10n.text("Installing Tart…"))
          } else {
            Label(L10n.text("Install Official Tart"), systemImage: "arrow.down.circle")
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isInstalling)

        Button {
          chooseExisting()
        } label: {
          Label(L10n.text("Choose Existing Tart…"), systemImage: "folder")
        }
        .disabled(isInstalling)
      }

      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          Text(L10n.text("Install with Homebrew"))
            .font(.caption.weight(.medium))

          HStack {
            Text("brew install openai/tools/tart")
              .font(.system(.body, design: .monospaced))
              .textSelection(.enabled)

            Spacer()

            Button {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString("brew install openai/tools/tart", forType: .string)
            } label: {
              Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(L10n.text("Copy"))
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
      }

      Text(L10n.text("TartUI downloads official Tart releases from GitHub, verifies the published checksum when available and the macOS code signature, then stores the runtime in your user Application Support folder."))
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Button(L10n.text("Check Again"), action: onRetry)
        .disabled(isInstalling)
    }
    .padding(32)
    .frame(maxWidth: 500)
  }

  private func chooseExisting() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.message = L10n.text("Choose the tart executable")
    panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")

    if panel.runModal() == .OK, let url = panel.url {
      onChooseExisting(url.path)
    }
  }
}
