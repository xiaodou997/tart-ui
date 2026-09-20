import Foundation
import Observation
import SwiftUI

@Observable
@MainActor
final class AppUpdateStore {
  private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL

    enum CodingKeys: String, CodingKey {
      case tagName = "tag_name"
      case htmlURL = "html_url"
    }
  }

  private static let latestReleaseURL = URL(
    string: "https://api.github.com/repos/xiaodou997/tart-ui/releases/latest"
  )!

  private(set) var latestVersion: String?
  private(set) var releaseURL: URL?
  private(set) var isChecking = false
  private(set) var error: String?
  private(set) var hasChecked = false
  private(set) var hasPublishedRelease = false

  var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? L10n.text("Development")
  }

  var buildVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
      ?? L10n.text("Development")
  }

  var isUpdateAvailable: Bool {
    guard let latestVersion else { return false }
    return TartRuntimeInstaller.isVersion(latestVersion, newerThan: currentVersion)
  }

  func check() async {
    guard !isChecking else { return }

    isChecking = true
    error = nil
    defer {
      isChecking = false
      hasChecked = true
    }

    do {
      var request = URLRequest(url: Self.latestReleaseURL)
      request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
      request.setValue("TartUI/\(currentVersion)", forHTTPHeaderField: "User-Agent")

      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw UpdateError.invalidResponse
      }

      if http.statusCode == 404 {
        hasPublishedRelease = false
        latestVersion = nil
        releaseURL = nil
        return
      }

      guard (200..<300).contains(http.statusCode) else {
        throw UpdateError.httpStatus(http.statusCode)
      }

      let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
      hasPublishedRelease = true
      latestVersion = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
      releaseURL = release.htmlURL
    } catch {
      self.error = error.localizedDescription
    }
  }

  private enum UpdateError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
      switch self {
      case .invalidResponse:
        return "GitHub returned an invalid update response."
      case let .httpStatus(code):
        return "GitHub update check failed with HTTP status \(code)."
      }
    }
  }
}

struct AboutView: View {
  let store: VMStore
  let updateStore: AppUpdateStore

  var body: some View {
    VStack(spacing: 18) {
      Image(systemName: "macwindow")
        .font(.system(size: 42))
        .foregroundStyle(.secondary)

      VStack(spacing: 4) {
        Text("TartUI")
          .font(.title.weight(.semibold))

        Text(L10n.text("A transparent macOS GUI for the Tart CLI."))
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
        GridRow {
          Text(L10n.text("TartUI Version"))
            .foregroundStyle(.secondary)
          Text(updateStore.currentVersion)
            .monospaced()
            .textSelection(.enabled)
        }

        GridRow {
          Text(L10n.text("Build"))
            .foregroundStyle(.secondary)
          Text(updateStore.buildVersion)
            .monospaced()
            .textSelection(.enabled)
        }

        GridRow {
          Text(L10n.text("Tart Version"))
            .foregroundStyle(.secondary)
          Text(store.tartVersion ?? L10n.text("Not Available"))
            .monospaced()
            .textSelection(.enabled)
        }
      }
      .font(.callout)

      Divider()

      updateSection

      HStack {
        Link(L10n.text("Project on GitHub"), destination: URL(string: "https://github.com/xiaodou997/tart-ui")!)
        Spacer()
        Link(L10n.text("Tart Project"), destination: URL(string: "https://github.com/openai/tart")!)
      }
      .font(.callout)
    }
    .padding(24)
    .frame(width: 430)
    .task {
      if !updateStore.hasChecked {
        await updateStore.check()
      }
    }
  }

  @ViewBuilder
  private var updateSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(L10n.text("TartUI Updates"))
          .font(.headline)

        Spacer()

        Button {
          Task { await updateStore.check() }
        } label: {
          if updateStore.isChecking {
            ProgressView().controlSize(.small)
          } else {
            Text(L10n.text("Check Again"))
          }
        }
        .buttonStyle(.glass)
        .disabled(updateStore.isChecking)
      }

      if updateStore.isChecking && !updateStore.hasChecked {
        Text(L10n.text("Checking for TartUI updates…"))
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if let error = updateStore.error {
        Text(error)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      } else if !updateStore.hasPublishedRelease {
        Text(L10n.text("No published TartUI release yet."))
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if updateStore.isUpdateAvailable, let latest = updateStore.latestVersion {
        HStack {
          Label(
            L10n.format("TartUI %@ is available.", latest),
            systemImage: "arrow.down.circle.fill"
          )
          .font(.caption)

          Spacer()

          if let releaseURL = updateStore.releaseURL {
            Link(L10n.text("View Release"), destination: releaseURL)
              .font(.caption)
          }
        }
      } else {
        Label(L10n.text("TartUI is up to date."), systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

struct TartUICommands: Commands {
  let onRefresh: () -> Void
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .appInfo) {
      Button(L10n.text("About TartUI")) {
        openWindow(id: "about")
      }
    }

    CommandGroup(after: .newItem) {
      Button(L10n.text("Refresh"), action: onRefresh)
        .keyboardShortcut("r")
    }
  }
}
