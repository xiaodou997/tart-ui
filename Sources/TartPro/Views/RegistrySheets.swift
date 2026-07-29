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
      Text("拉取镜像")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()

      Divider()

      Form {
        Section("镜像引用") {
          TextField("引用", text: $reference, prompt: Text("如 ghcr.io/cirruslabs/ubuntu:latest"))
            .onSubmit { commitIfValid() }
        }

        if !recentReferences.isEmpty {
          Section("本地已有") {
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

        Section("常用镜像") {
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
          DisclosureGroup("高级选项", isExpanded: $showAdvanced) {
            HStack {
              Text("网络并发数")
              Slider(value: $concurrency, in: 1...16, step: 1)
              Text("\(Int(concurrency))").monospacedDigit().frame(width: 30)
            }
            Toggle("允许不安全的 HTTP 连接", isOn: $insecure)
          }
        } footer: {
          Text("镜像通常有几十 GB，下载需要较长时间。可以在拉取过程中继续使用其他功能。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("拉取") { commitIfValid() }
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
        Text("推送到仓库").font(.headline)
        Text(localName).font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding()

      Divider()

      Form {
        Section {
          ForEach(targets.indices, id: \.self) { index in
            HStack {
              TextField("", text: $targets[index], prompt: Text("如 ghcr.io/org/image:v1"))
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
            Label("添加目标", systemImage: "plus")
              .font(.caption)
          }
          .buttonStyle(.borderless)
        } header: {
          Text("目标引用")
        } footer: {
          Text("可以一次推送到多个引用，比如同时打上版本号和 latest。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section("标签") {
          ForEach(labels.indices, id: \.self) { index in
            HStack {
              TextField("键", text: $labels[index].key)
                .textFieldStyle(.roundedBorder)
              TextField("值", text: $labels[index].value)
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
            Label("添加标签", systemImage: "plus").font(.caption)
          }
          .buttonStyle(.borderless)
        }

        Section {
          DisclosureGroup("高级选项", isExpanded: $showAdvanced) {
            HStack {
              Text("网络并发数")
              Slider(value: $concurrency, in: 1...16, step: 1)
              Text("\(Int(concurrency))").monospacedDigit().frame(width: 30)
            }

            Toggle("使用分块上传", isOn: $useChunkedUpload)

            if useChunkedUpload {
              HStack {
                Text("块大小")
                Slider(value: $chunkSizeMB, in: 1...100, step: 1)
                Text("\(Int(chunkSizeMB)) MB").monospacedDigit().frame(width: 60)
              }
              // 各家仓库的限制差别很大，写清楚免得用户反复试。
              Text("各仓库要求不同：AWS ECR 只接受大于 5 MB 的块，GitHub Container Registry 只接受小于 4 MB 的，Google Container Registry 不支持分块。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Toggle("同时缓存到本地", isOn: $populateCache)
              .help("占用额外磁盘，但之后重新拉取会快很多")

            Toggle("允许不安全的 HTTP 连接", isOn: $insecure)
          }
        }
      }
      .formStyle(.grouped)

      Divider()

      HStack {
        Text("推送前需要先登录目标仓库。")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("取消") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("推送") {
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
      Text("仓库账号")
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()

      Divider()

      Form {
        Picker("", selection: $mode) {
          Text("登录").tag(Mode.login)
          Text("注销").tag(Mode.logout)
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        Section {
          TextField("仓库地址", text: $host, prompt: Text("如 ghcr.io"))

          if mode == .login {
            TextField("用户名", text: $username)
            SecureField("密码或访问令牌", text: $password)
          }
        } footer: {
          if mode == .login {
            // 说清楚密码去了哪里，这是用户会关心的。
            Text("凭据由 tart 保存到系统钥匙串，TartPro 不会存储密码。密码通过标准输入传递，不会出现在进程列表中。")
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text("将从钥匙串中移除该仓库的凭据。")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if mode == .login {
          Section("选项") {
            Toggle("登录前验证凭据", isOn: $validate)
              .help("关闭后即使仓库暂时不可达也能保存凭据")
            Toggle("允许不安全的 HTTP 连接", isOn: $insecure)
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
        Text("tart 未提供查询已登录仓库的方式。")
          .font(.caption)
          .foregroundStyle(.secondary)

        Spacer()

        Button("关闭") { dismiss() }
          .keyboardShortcut(.cancelAction)

        Button(mode == .login ? "登录" : "注销") {
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
      message = Message(text: mode == .login ? "登录成功。" : "已注销。", isError: false)
      // 成功后立刻清掉密码，不在内存里多留。
      password = ""
    }
  }
}
