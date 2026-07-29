import SwiftUI

/// tart 不可用时的引导页。
///
/// 从 Finder 启动的 .app 拿不到 shell 的 PATH，这是最常见的首次运行故障。
/// 与其静默失败，不如把原因和处理办法直接说清楚。
struct SetupGuideView: View {
  let message: String
  let onRetry: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 40))
        .foregroundStyle(.orange)

      Text("找不到 tart")
        .font(.title2.weight(.semibold))

      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .textSelection(.enabled)

      GroupBox {
        VStack(alignment: .leading, spacing: 8) {
          Text("如果还没安装，在终端里执行：")
            .font(.caption)
            .foregroundStyle(.secondary)

          Text("brew install openai/tools/tart")
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
      }

      Button("重新检测", action: onRetry)
        .keyboardShortcut(.defaultAction)
    }
    .padding(32)
    .frame(maxWidth: 460)
  }
}
