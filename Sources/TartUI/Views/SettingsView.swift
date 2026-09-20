import SwiftUI
import TartKit

struct SettingsView: View {
  let store: VMStore
  let languageStore: AppLanguageStore

  @State private var binaryPath = ""
  @State private var isValidating = false
  @State private var validationResult: ValidationResult?

  private struct ValidationResult {
    let message: String
    let isSuccess: Bool
  }

  var body: some View {
    @Bindable var languageStore = languageStore

    Form {
      Section {
        Picker(L10n.text("Application Language"), selection: $languageStore.selection) {
          ForEach(AppLanguage.allCases) { language in
            Text(language.title).tag(language)
          }
        }
      } header: {
        Text(L10n.text("Language"))
      } footer: {
        Text(L10n.text("Language changes apply immediately. System Default follows the language selected for TartUI in macOS."))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        LabeledContent(L10n.text("Status")) {
          Text(store.runtime == nil ? L10n.text("Not Available") : L10n.text("Installed"))
            .foregroundStyle(store.runtime == nil ? .red : .primary)
        }

        if let version = store.tartVersion {
          LabeledContent(L10n.text("Version")) {
            Text(version)
              .font(.system(.body, design: .monospaced))
          }
        }

        if let runtime = store.runtime {
          LabeledContent(L10n.text("Source")) {
            Text(runtimeSourceTitle(runtime.source))
          }

          LabeledContent(L10n.text("Executable")) {
            Text(runtime.binaryURL.path)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .multilineTextAlignment(.trailing)
          }
        }

        if let latest = store.latestOfficialTartVersion {
          LabeledContent(L10n.text("Latest Official")) {
            Text(latest)
              .font(.system(.body, design: .monospaced))
          }

          if store.isRuntimeUpdateAvailable {
            if store.runtimeSource == .managed {
              Button {
                Task { await store.installLatestRuntime() }
              } label: {
                if store.isInstallingRuntime {
                  ProgressView().controlSize(.small)
                  Text(L10n.text("Updating Tart…"))
                } else {
                  Label(L10n.text("Update Managed Tart"), systemImage: "arrow.down.circle")
                }
              }
              .disabled(store.isInstallingRuntime)
            } else {
              Label(
                L10n.text("A newer official Tart release is available. Update the current installation with the method you used to install it."),
                systemImage: "arrow.up.circle"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }
          } else if store.tartVersion != nil {
            Label(L10n.text("Tart is up to date."), systemImage: "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        HStack {
          Button {
            Task { await store.checkForRuntimeUpdate() }
          } label: {
            if store.isCheckingRuntimeUpdate {
              ProgressView().controlSize(.small)
              Text(L10n.text("Checking for Updates…"))
            } else {
              Label(L10n.text("Check for Official Updates"), systemImage: "arrow.triangle.2.circlepath")
            }
          }
          .disabled(store.isCheckingRuntimeUpdate || store.runtime == nil)

          if let previous = store.previousManagedVersion {
            Button(L10n.format("Roll Back to %@", previous)) {
              Task { await store.rollbackManagedRuntime(to: previous) }
            }
          }
        }

        if let error = store.runtimeUpdateError ?? store.runtimeInstallError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      } header: {
        Text(L10n.text("Tart Runtime"))
      } footer: {
        Text(L10n.text("System Tart installations are preferred. If none is available, TartUI can use an official release stored in Application Support."))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section {
        HStack {
          TextField(
            L10n.text("tart Path"),
            text: $binaryPath,
            prompt: Text(L10n.text("Leave blank to detect automatically"))
          )
          .textFieldStyle(.roundedBorder)

          Button(L10n.text("Choose…")) { choosePath() }

          Button(isValidating ? L10n.text("Checking…") : L10n.text("Check and Apply")) {
            Task { await validateAndApply() }
          }
          .disabled(isValidating)
        }

        if let validationResult {
          Label(
            validationResult.message,
            systemImage: validationResult.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill"
          )
          .font(.caption)
          .foregroundStyle(validationResult.isSuccess ? .green : .red)
        }

        if TartLocator.storedUserOverride() != nil {
          Button(L10n.text("Use Automatic Detection")) {
            binaryPath = ""
            Task { await validateAndApply() }
          }
        }
      } header: {
        Text(L10n.text("Runtime Selection"))
      } footer: {
        Text(L10n.text("Automatic detection checks standard Homebrew locations and PATH first, then falls back to a TartUI-managed runtime. A manual path is saved only after it passes validation."))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

    }
    .formStyle(.grouped)
    .frame(width: 620, height: 500)
    .onAppear {
      binaryPath = TartLocator.storedUserOverride() ?? ""
    }
  }

  private func runtimeSourceTitle(_ source: TartRuntimeSource) -> String {
    switch source {
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
    panel.showsHiddenFiles = true

    if panel.runModal() == .OK, let url = panel.url {
      binaryPath = url.path
      Task { await validateAndApply() }
    }
  }

  private func validateAndApply() async {
    isValidating = true
    defer { isValidating = false }

    let path = binaryPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let error = await store.applyRuntimePath(path.isEmpty ? nil : path)

    if let error {
      validationResult = ValidationResult(message: error, isSuccess: false)
    } else {
      binaryPath = TartLocator.storedUserOverride() ?? ""
      let version = store.tartVersion ?? ""
      validationResult = ValidationResult(
        message: L10n.format("Using tart %@.", version),
        isSuccess: true
      )
    }
  }
}
