import SwiftUI
import TartKit

/// 从 OCI 仓库拉取镜像。
struct PullImageSheet: View {
  let recentReferences: [String]
  let onPull: (String, Bool, UInt?) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var reference = ""
  @State private var insecure = false
  @State private var concurrency = 4.0
  @State private var showAdvanced = false

  /// 官方提供的常用基础镜像，省得用户去查完整引用。
  private let suggestions = [
    "ghcr.io/cirruslabs/macos-sequoia-base:latest",
    "ghcr.io/cirruslabs/macos-sequoia-xcode:latest",
    "ghcr.io/cirruslabs/ubuntu:latest",
  ]

  var body: some View {
    VStack(spacing: 0) {
      Text(L10n.text("Pull Image"))
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()

      Divider()

      Form {
        Section(L10n.text("Image Reference")) {
          TextField(L10n.text("Reference"), text: $reference, prompt: Text(L10n.text("e.g. ghcr.io/cirruslabs/ubuntu:latest")))
            .onSubmit { commitIfValid() }
        }

        if !recentReferences.isEmpty {
          Section(L10n.text("Already Local")) {
            ForEach(recentReferences.prefix(5), id: \.self) { item in
              Button {
                reference = item
              } label: {
                Text(item)
                  .font(.system(.caption, design: .monospaced))
                  .lineLimit(1)
                  .truncationMode(.middle)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .buttonStyle(.plain)
            }
          }
        }

        Section(L10n.text("Suggested Images")) {
          ForEach(suggestions, id: \.self) { item in
            Button {
              reference = item
            } label: {
              Text(item)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
          }
        }

        Section {
          DisclosureGroup(L10n.text("Advanced Options"), isExpanded: $showAdvanced) {
            HStack {
              Text(L10n.text("Network Concurrency"))
              Slider(value: $concurrency, in: 1...16, step: 1)
              Text(String(Int(concurrency))).monospacedDigit().frame(width: 30)
            }
            Toggle(L10n.text("Allow Insecure HTTP"), isOn: $insecure)
          }
        } footer: {
          Text(L10n.text("Images are often tens of GB and may take a while to download. You can continue using other features during the pull."))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Spacer()
        Button(L10n.text("Cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(L10n.text("Pull")) { commitIfValid() }
          .keyboardShortcut(.defaultAction)
          .disabled(reference.isEmpty)
      }
      .padding()
    }
    .frame(width: 540, height: 520)
  }

  private func commitIfValid() {
    guard !reference.isEmpty else { return }
    onPull(reference, insecure, UInt(concurrency))
    dismiss()
  }
}

/// 把本地虚拟机推送到 OCI 仓库。
struct PushImageSheet: View {
  let localName: String
  let onPush: (String, [String], Bool, UInt?, Int?, [ImageLabel], Bool) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var targets: [String] = [""]
  @State private var labels: [ImageLabel] = []
  @State private var insecure = false
  @State private var concurrency = 4.0
  @State private var useChunkedUpload = false
  @State private var chunkSizeMB = 4.0
  @State private var populateCache = false
  @State private var showAdvanced = false

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 2) {
        Text(L10n.text("Push to Registry")).font(.headline)
        Text(localName).font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()

      Divider()

      Form {
        Section {
          ForEach(targets.indices, id: \.self) { index in
            HStack {
              TextField("", text: $targets[index], prompt: Text(L10n.text("e.g. ghcr.io/org/image:v1")))
                .textFieldStyle(.roundedBorder)
              if targets.count > 1 {
                Button {
                  targets.remove(at: index)
                } label: {
                  Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
              }
            }
          }

          Button {
            targets.append("")
          } label: {
            Label(L10n.text("Add Target"), systemImage: "plus")
              .font(.caption)
          }
          .buttonStyle(.borderless)
        } header: {
          Text(L10n.text("Target References"))
        } footer: {
          Text(L10n.text("Push to multiple references at once, such as a version tag and latest."))
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section(L10n.text("Labels")) {
          ForEach(labels.indices, id: \.self) { index in
            HStack {
              TextField(L10n.text("Key"), text: $labels[index].key)
                .textFieldStyle(.roundedBorder)
              TextField(L10n.text("Value"), text: $labels[index].value)
                .textFieldStyle(.roundedBorder)
              Button {
                labels.remove(at: index)
              } label: {
                Image(systemName: "minus.circle")
              }
              .buttonStyle(.borderless)
            }
          }

          Button {
            labels.append(ImageLabel(key: "", value: ""))
          } label: {
            Label(L10n.text("Add Label"), systemImage: "plus").font(.caption)
          }
          .buttonStyle(.borderless)
        }

        Section {
          DisclosureGroup(L10n.text("Advanced Options"), isExpanded: $showAdvanced) {
            HStack {
              Text(L10n.text("Network Concurrency"))
              Slider(value: $concurrency, in: 1...16, step: 1)
              Text(String(Int(concurrency))).monospacedDigit().frame(width: 30)
            }

            Toggle(L10n.text("Use Chunked Upload"), isOn: $useChunkedUpload)

            if useChunkedUpload {
              HStack {
                Text(L10n.text("Chunk Size"))
                Slider(value: $chunkSizeMB, in: 1...100, step: 1)
                Text(L10n.format("%@ MB", String(Int(chunkSizeMB)))).monospacedDigit().frame(width: 60)
              }
              // 各家仓库的限制差别很大，写清楚免得用户反复试。
              Text(L10n.text("Registry requirements differ: AWS ECR accepts chunks larger than 5 MB, GitHub Container Registry accepts chunks smaller than 4 MB, and Google Container Registry does not support chunks."))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Toggle(L10n.text("Populate Local Cache"), isOn: $populateCache)
              .help(L10n.text("Uses extra disk space but makes future pulls much faster"))

            Toggle(L10n.text("Allow Insecure HTTP"), isOn: $insecure)
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Text(L10n.text("Log in to the target registry before pushing."))
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(L10n.text("Cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(L10n.text("Push")) {
          onPush(
            localName,
            validTargets,
            insecure,
            UInt(concurrency),
            useChunkedUpload ? Int(chunkSizeMB) : nil,
            labels.filter { !$0.key.isEmpty },
            populateCache
          )
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(validTargets.isEmpty)
      }
      .padding()
    }
    .frame(width: 560, height: 600)
  }

  private var validTargets: [String] {
    targets.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }
}

/// 仓库登录与注销。
struct RegistryLoginSheet: View {
  let onLogin: (String, String, String, Bool, Bool) async -> String?
  let onLogout: (String) async -> String?

  @Environment(\.dismiss) private var dismiss

  @State private var mode: Mode = .login
  @State private var host = ""
  @State private var username = ""
  @State private var password = ""
  @State private var insecure = false
  @State private var validate = true
  @State private var isWorking = false
  @State private var message: Message?

  private enum Mode: Hashable {
    case login, logout
  }

  private struct Message {
    let text: String
    let isError: Bool
  }

  var body: some View {
    VStack(spacing: 0) {
      Text(L10n.text("Registry Accounts"))
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()

      Divider()

      Form {
        Picker("", selection: $mode) {
          Text(L10n.text("Log In")).tag(Mode.login)
          Text(L10n.text("Log Out")).tag(Mode.logout)
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        Section {
          TextField(L10n.text("Registry Host"), text: $host, prompt: Text(L10n.text("e.g. ghcr.io")))

          if mode == .login {
            TextField(L10n.text("Username"), text: $username)
            SecureField(L10n.text("Password or Access Token"), text: $password)
          }
        } footer: {
          if mode == .login {
            // 说清楚密码去了哪里，这是用户会关心的。
            Text(L10n.text("tart stores credentials in the system Keychain. TartUI does not store the password; it is passed through stdin and never appears in the process list."))
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text(L10n.text("Credentials for this registry will be removed from the Keychain."))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if mode == .login {
          Section(L10n.text("Options")) {
            Toggle(L10n.text("Validate Credentials Before Login"), isOn: $validate)
              .help(L10n.text("When disabled, credentials can be saved even if the registry is temporarily unreachable"))
            Toggle(L10n.text("Allow Insecure HTTP"), isOn: $insecure)
          }
        }

        if let message {
          Section {
            Label(message.text, systemImage: message.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
              .font(.caption)
              .foregroundStyle(message.isError ? .red : .green)
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        // tart 没有「列出已登录仓库」的命令，所以这里无法显示登录状态。
        Text(L10n.text("tart does not provide a way to list logged-in registries."))
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        Button(L10n.text("Close")) { dismiss() }
          .keyboardShortcut(.cancelAction)

        Button(mode == .login ? L10n.text("Log In") : L10n.text("Log Out")) {
          Task { await submit() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit || isWorking)
      }
      .padding()
    }
    .frame(width: 520, height: 480)
  }

  private var canSubmit: Bool {
    guard !host.isEmpty else { return false }
    if mode == .login {
      return !username.isEmpty && !password.isEmpty
    }
    return true
  }

  private func submit() async {
    isWorking = true
    defer { isWorking = false }

    let error: String?
    if mode == .login {
      error = await onLogin(host, username, password, insecure, validate)
    } else {
      error = await onLogout(host)
    }

    if let error {
      message = Message(text: error, isError: true)
    } else {
      message = Message(text: mode == .login ? L10n.text("Login succeeded.") : L10n.text("Logged out."), isError: false)
      // 成功后立刻清掉密码，不在内存里多留。
      password = ""
    }
  }
}
