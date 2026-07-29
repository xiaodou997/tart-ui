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
        if binaryPath.isEmpty {
          LabeledContent("当前使用") {
            Text(store.tartVersion.map { "tart \($0)" } ?? "未找到")
              .foregroundStyle(store.tartVersion == nil ? .red : .primary)
          }
        }

        HStack {
          TextField("tart 路径", text: $binaryPath, prompt: Text("留空则自动探测"))
            .textFieldStyle(.roundedBorder)
          Button("选择…") { choosePath() }
          if !binaryPath.isEmpty {
            Button("清除") {
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
          Button(isValidating ? "检测中…" : "检测并应用") {
            Task { await validate() }
          }
          .disabled(isValidating)
        }
      } header: {
        Text("tart 可执行文件")
      } footer: {
        // 说明为什么会需要手动指路，否则这个设置项看起来莫名其妙。
        Text("""
          默认按 /opt/homebrew/bin、/usr/local/bin 的顺序探测。
          从访达启动的应用拿不到终端的 PATH 环境变量，如果 tart 装在其他位置，就需要在这里手动指定。
          """)
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("存储位置") {
        LabeledContent("启动配置") {
          Button("在访达中显示") {
            if let url = try? RunProfileStore.defaultFileURL() {
              NSWorkspace.shared.activateFileViewerSelecting([url])
            }
          }
          .buttonStyle(.link)
        }

        LabeledContent("运行日志") {
          Button("在访达中显示") {
            let url = FileManager.default
              .homeDirectoryForCurrentUser
              .appendingPathComponent("Library/Logs/TartPro")
            NSWorkspace.shared.activateFileViewerSelecting([url])
          }
          .buttonStyle(.link)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 400)
  }

  private func choosePath() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    panel.message = "选择 tart 可执行文件"
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
      validationResult = ValidationResult(message: "找到 tart \(version)。", isSuccess: true)
      // 重新初始化，让新路径立刻生效。
      await store.bootstrap(userOverride: override)
    } catch {
      validationResult = ValidationResult(message: error.localizedDescription, isSuccess: false)
    }
  }
}
