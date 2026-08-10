import AppKit
import SwiftUI

/// tart 不可用时的引导页。
///
/// 从 Finder 启动的 .app 拿不到 shell 的 PATH，这是最常见的首次运行故障。
/// 与其静默失败，不如把原因和处理办法直接说清楚。
struct SetupGuideView: View {
  let message: String
  let isInstalling: Bool
  let onInstall: () -> Void
  let onRetry: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 40))
        .foregroundStyle(.orange)

      Text(L10n.text("tart Not Found"))
        .font(.title2.weight(.semibold))

      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)

      Text(L10n.text("TartUI can install the official Tart runtime for you."))
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Button {
        onInstall()
      } label: {
        if isInstalling {
          ProgressView()
            .controlSize(.small)
          Text(L10n.text("Installing Tart…"))
        } else {
          Label(L10n.text("Install Tart Runtime"), systemImage: "arrow.down.circle")
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(isInstalling)

      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          Text(L10n.text("Advanced: install with Homebrew"))
            .font(.caption)
            .foregroundStyle(.secondary)

          Text("brew install openai/tools/tart")
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
      }

      HStack {
        Button(L10n.text("Open Settings…")) {
          // 装在非标准位置时，用户需要在设置里手动指路。
          NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        Button(L10n.text("Check Again"), action: onRetry)
          .keyboardShortcut(.defaultAction)
          .disabled(isInstalling)
      }
    }
    .padding(32)
    .frame(maxWidth: 460)
  }
}
