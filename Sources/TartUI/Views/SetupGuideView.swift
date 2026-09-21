import AppKit
import SwiftUI

/// First-run recovery screen shown when the selected Tart runtime is unavailable.
struct SetupGuideView: View {
  let message: String
  let isInstalling: Bool
  let onUseManaged: () -> Void
  let onUseSystem: () -> Void
  let onChooseCustom: (String) -> Void
  let onRetry: () -> Void

  var body: some View {
    VStack(spacing: 22) {
      Image(systemName: "shippingbox.and.arrow.backward")
        .font(.system(size: 42))
        .foregroundStyle(Color.accentColor)

      VStack(spacing: 6) {
        Text(L10n.text("Tart Required"))
          .font(.title2.weight(.semibold))

        Text(L10n.text("TartUI needs the official Tart CLI to create and run virtual machines. Choose how Tart should be provided."))
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      HStack(alignment: .top, spacing: 12) {
        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Label(L10n.text("Application Managed"), systemImage: "shippingbox")
                .font(.headline)

              Spacer()

              Text(L10n.text("Recommended"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }

            Text(L10n.text("TartUI downloads the official release into Application Support and manages updates and rollback."))
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button {
              onUseManaged()
            } label: {
              if isInstalling {
                ProgressView()
                  .controlSize(.small)
                Text(L10n.text("Installing Tart…"))
              } else {
                Label(L10n.text("Use Application Managed"), systemImage: "arrow.down.circle")
              }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(isInstalling)
          }
          .padding(6)
          .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        }

        GroupBox {
          VStack(alignment: .leading, spacing: 12) {
            Label(L10n.text("System Tart"), systemImage: "terminal")
              .font(.headline)

            Text(L10n.text("Use Tart already installed by Homebrew or available on PATH. TartUI will not modify it."))
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            Button {
              onUseSystem()
            } label: {
              Label(L10n.text("Detect System Tart"), systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(isInstalling)
          }
          .padding(6)
          .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        }
      }
      .frame(maxWidth: 540)

      Button {
        chooseCustom()
      } label: {
        Label(L10n.text("Choose Custom Tart…"), systemImage: "folder")
      }
      .buttonStyle(.borderless)
      .disabled(isInstalling)

      if !message.isEmpty {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .textSelection(.enabled)
          .padding(.horizontal, 12)
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
      .frame(maxWidth: 540)

      Text(L10n.text("Application Managed Tart is downloaded from official GitHub releases, verified, and stored in your user Application Support folder."))
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)

      Button(L10n.text("Check Again"), action: onRetry)
        .buttonStyle(.glass)
        .disabled(isInstalling)
    }
    .padding(32)
    .frame(maxWidth: 620)
  }

  private func chooseCustom() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.showsHiddenFiles = true
    panel.message = L10n.text("Choose the tart executable")
    panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")

    if panel.runModal() == .OK, let url = panel.url {
      onChooseCustom(url.path)
    }
  }
}
