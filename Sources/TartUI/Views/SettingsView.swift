import AppKit
import SwiftUI
import TartKit

struct SettingsView: View {
  let store: VMStore
  let languageStore: AppLanguageStore

  @State private var selectionError: String?

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
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
              Text(L10n.text("Tart CLI"))
                .font(.headline)

              runtimeStatus
            }

            Text(L10n.text("TartUI uses the official Tart CLI to create and run virtual machines."))
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer()

          Menu {
            Button {
              selectSource(.managed)
            } label: {
              Label(
                L10n.text("Application Managed"),
                systemImage: store.runtimePreference == .managed ? "checkmark" : "shippingbox"
              )
            }

            Button {
              selectSource(.system)
            } label: {
              Label(
                L10n.text("System Tart"),
                systemImage: store.runtimePreference == .system ? "checkmark" : "terminal"
              )
            }

            Divider()

            Button {
              chooseCustomPath()
            } label: {
              Label(
                L10n.text("Custom Path…"),
                systemImage: store.runtimePreference == .custom ? "checkmark" : "folder"
              )
            }
          } label: {
            HStack(spacing: 6) {
              Text(runtimePreferenceTitle(store.runtimePreference))
              Image(systemName: "chevron.up.chevron.down")
                .font(.caption2)
            }
            .frame(minWidth: 145)
          }
          .buttonStyle(.glass)
          .disabled(store.isInstallingRuntime)
        }

        if let runtime = store.runtime {
          LabeledContent(L10n.text("Version")) {
            Text(store.tartVersion ?? "—")
              .font(.system(.body, design: .monospaced))
          }

          LabeledContent(L10n.text("Path")) {
            HStack(spacing: 8) {
              Text(runtime.binaryURL.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)

              Button {
                copy(runtime.binaryURL.path)
              } label: {
                Image(systemName: "doc.on.doc")
              }
              .buttonStyle(.borderless)
              .help(L10n.text("Copy"))

              Button {
                NSWorkspace.shared.activateFileViewerSelecting([runtime.binaryURL])
              } label: {
                Image(systemName: "folder")
              }
              .buttonStyle(.borderless)
              .help(L10n.text("Show in Finder"))
            }
          }

          if let latest = store.latestOfficialTartVersion {
            LabeledContent(L10n.text("Latest Official")) {
              Text(latest)
                .font(.system(.body, design: .monospaced))
            }

            if store.isRuntimeUpdateAvailable {
              if store.runtimePreference == .managed {
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
                  L10n.text("A newer official Tart release is available. Update this Tart with the method that manages it."),
                  systemImage: "arrow.up.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                if isHomebrewRuntime(runtime) {
                  HStack(spacing: 8) {
                    Text("brew upgrade openai/tools/tart")
                      .font(.system(.caption, design: .monospaced))
                      .textSelection(.enabled)

                    Button {
                      copy("brew upgrade openai/tools/tart")
                    } label: {
                      Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.text("Copy"))
                  }
                }
              }
            } else if store.tartVersion != nil {
              Label(L10n.text("Tart is up to date."), systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          HStack(spacing: 10) {
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
            .disabled(store.isCheckingRuntimeUpdate || store.isInstallingRuntime)

            if let previous = store.previousManagedVersion {
              Button(L10n.format("Roll Back to %@", previous)) {
                Task { await store.rollbackManagedRuntime(to: previous) }
              }
              .disabled(store.isInstallingRuntime)
            }

            if store.runtimePreference == .custom {
              Button(L10n.text("Choose Another…")) {
                chooseCustomPath()
              }
            }
          }

          Text(sourceHelpText(store.runtimePreference))
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
          Text(sourceHelpText(store.runtimePreference))
            .font(.caption)
            .foregroundStyle(.secondary)

          switch store.runtimePreference {
          case .managed:
            Button {
              selectSource(.managed)
            } label: {
              if store.isInstallingRuntime {
                ProgressView().controlSize(.small)
                Text(L10n.text("Installing Tart…"))
              } else {
                Label(L10n.text("Install Official Tart"), systemImage: "arrow.down.circle")
              }
            }
            .disabled(store.isInstallingRuntime)

          case .system:
            Button {
              selectSource(.system)
            } label: {
              Label(L10n.text("Detect System Tart"), systemImage: "arrow.triangle.2.circlepath")
            }

          case .custom:
            Button(L10n.text("Choose Custom Tart…")) {
              chooseCustomPath()
            }
          }
        }

        if let error = visibleRuntimeError {
          Text(error)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
      } header: {
        Text(L10n.text("Tart Runtime"))
      }
    }
    .formStyle(.grouped)
    .frame(width: 660, height: 520)
    .task {
      if store.runtime != nil, store.latestOfficialTartVersion == nil {
        await store.checkForRuntimeUpdate()
      }
    }
  }

  @ViewBuilder
  private var runtimeStatus: some View {
    if store.runtime != nil {
      Label(L10n.text("Installed"), systemImage: "checkmark.circle.fill")
        .font(.caption.weight(.medium))
        .foregroundStyle(.green)
    } else {
      Label(L10n.text("Not Available"), systemImage: "exclamationmark.circle.fill")
        .font(.caption.weight(.medium))
        .foregroundStyle(.red)
    }
  }

  private var visibleRuntimeError: String? {
    selectionError
      ?? store.runtimeSelectionError
      ?? store.runtimeUpdateError
      ?? store.runtimeInstallError
  }

  private func runtimePreferenceTitle(_ preference: TartRuntimePreference) -> String {
    switch preference {
    case .managed:
      return L10n.text("Application Managed")
    case .system:
      return L10n.text("System Tart")
    case .custom:
      return L10n.text("Custom Path")
    }
  }

  private func sourceHelpText(_ preference: TartRuntimePreference) -> String {
    switch preference {
    case .managed:
      return L10n.text("TartUI downloads and manages the official Tart release in Application Support, including updates and rollback.")
    case .system:
      return L10n.text("Uses Tart installed by Homebrew or available on PATH. TartUI will not modify the system installation.")
    case .custom:
      return L10n.text("Uses exactly the Tart executable you choose. TartUI validates the path before saving it.")
    }
  }

  private func selectSource(_ preference: TartRuntimePreference) {
    selectionError = nil
    Task {
      selectionError = await store.useRuntimePreference(preference)
    }
  }

  private func chooseCustomPath() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = L10n.text("Choose the tart executable")
    panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
    panel.showsHiddenFiles = true

    if panel.runModal() == .OK, let url = panel.url {
      selectionError = nil
      Task {
        selectionError = await store.applyRuntimePath(url.path)
      }
    }
  }

  private func isHomebrewRuntime(_ runtime: TartRuntime) -> Bool {
    runtime.source == .system && runtime.binaryURL.path.hasPrefix("/opt/homebrew/")
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }
}
