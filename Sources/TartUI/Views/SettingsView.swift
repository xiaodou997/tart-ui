import SwiftUI
import TartKit

struct SettingsView: View {
  let store: VMStore

  @AppStorage(TartLocator.userOverrideDefaultsKey) private var binaryPath = ""
  @State private var isValidating = false
  @State private var validationResult: ValidationResult?

  private struct ValidationResult {
    let message: String
    let isSuccess: Bool
  }

  var body: some View {
    Form {
      Section {
        LabeledContent(L10n.text("Status")) {
          if let runtime = store.runtime {
            VStack(alignment: .trailing, spacing: 2) {
              Text(runtimeSourceTitle(runtime.source))
              if let version = store.tartVersion {
                Text(version)
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          } else {
            Text(L10n.text("Not Available"))
              .foregroundStyle(.red)
          }
        }

        if let runtime = store.runtime {
          LabeledContent(L10n.text("Executable")) {
            Text(runtime.binaryURL.path)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .multilineTextAlignment(.trailing)
          }
        }

        Button {
          Task { await store.installLatestRuntime() }
        } label: {
          if store.isInstallingRuntime {
            ProgressView()
              .controlSize(.small)
            Text(L10n.text("Updating Tart…"))
          } else {
            Label(L10n.text("Install or Update Managed Runtime"), systemImage: "arrow.triangle.2.circlepath")
          }
        }
        .disabled(store.isInstallingRuntime)

        if let error = store.runtimeInstallError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      } header: {
        Text(L10n.text("Tart Runtime"))
      } footer: {
        Text(L10n.text("TartUI uses its bundled runtime when available. This action installs or updates a managed fallback; bundled Tart is updated with new TartUI releases."))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        LabeledContent(L10n.text("Currently Using")) {
          Text(store.tartVersion.map { L10n.format("tart %@", $0) } ?? L10n.text("Not Found"))
            .foregroundStyle(store.tartVersion == nil ? .red : .primary)
        }

        HStack {
          TextField(L10n.text("tart Path"), text: $binaryPath, prompt: Text(L10n.text("Leave blank to detect automatically")))
            .textFieldStyle(.roundedBorder)
          Button(L10n.text("Choose…")) { choosePath() }
          if !binaryPath.isEmpty {
            Button(L10n.text("Clear")) {
              binaryPath = ""
              validationResult = nil
            }
          }
        }

        if let validationResult {
          Label(
            validationResult.message,
            systemImage: validationResult.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill"
          )
          .font(.caption)
          .foregroundStyle(validationResult.isSuccess ? .green : .red)
        }

        HStack {
          Spacer()
          Button(isValidating ? L10n.text("Checking…") : L10n.text("Check and Apply")) {
            Task { await validate() }
          }
          .disabled(isValidating)
        }
      } header: {
        Text(L10n.text("tart Executable"))
      } footer: {
        // 说明为什么会需要手动指路，否则这个设置项看起来莫名其妙。
        Text(L10n.text("By default, TartUI checks /opt/homebrew/bin and /usr/local/bin.\nApps launched from Finder do not inherit Terminal's PATH, so specify the path here if tart is installed elsewhere."))
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section(L10n.text("Storage Locations")) {
        LabeledContent(L10n.text("Run Profiles")) {
          Button(L10n.text("Show in Finder")) {
            if let url = try? RunProfileStore.defaultFileURL() {
              NSWorkspace.shared.activateFileViewerSelecting([url])
            }
          }
          .buttonStyle(.link)
        }

        LabeledContent(L10n.text("Run Logs")) {
          Button(L10n.text("Show in Finder")) {
            let url = FileManager.default
              .homeDirectoryForCurrentUser
              .appendingPathComponent("Library/Logs/TartUI")
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
          .buttonStyle(.link)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 400)
    .onAppear {
      if binaryPath.isEmpty {
        binaryPath = TartLocator.storedUserOverride() ?? ""
      }
    }
  }

  private func runtimeSourceTitle(_ source: TartRuntimeSource) -> String {
    switch source {
    case .bundled:
      return L10n.text("Built-in Tart")
    case .managed:
      return L10n.text("TartUI Managed Runtime")
    case .userOverride:
      return L10n.text("Manual Path")
    case .system:
      return L10n.text("System Tart")
    }
  }

  private func choosePath() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = L10n.text("Choose the tart executable")
    panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
    // tart 装在 /opt 这类隐藏目录下，得让用户能看到。
    panel.showsHiddenFiles = true

    if panel.runModal() == .OK, let url = panel.url {
      binaryPath = url.path
      Task { await validate() }
    }
  }

  private func validate() async {
    isValidating = true
    defer { isValidating = false }

    let override = binaryPath.isEmpty ? nil : binaryPath

    do {
      let client = try TartClient(userOverride: override)
      let version = try await client.version()
      validationResult = ValidationResult(message: L10n.format("Found tart %@.", version), isSuccess: true)
      // 重新初始化，让新路径立刻生效。
      await store.bootstrap(userOverride: override)
    } catch {
      validationResult = ValidationResult(message: error.localizedDescription, isSuccess: false)
    }
  }
}
