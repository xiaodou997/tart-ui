import SwiftUI
import TartKit

private let commonImageReferences = [
  "ghcr.io/cirruslabs/macos-sequoia-base:latest",
  "ghcr.io/cirruslabs/macos-sequoia-xcode:latest",
  "ghcr.io/cirruslabs/ubuntu:latest",
]

/// Primary registry flow: clone an OCI image directly into a runnable local VM.
struct CloneImageSheet: View {
  let existingNames: Set<String>
  let cachedReferences: [String]
  let onClone: (String, String, Bool) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var reference = ""
  @State private var newName = ""
  @State private var lastSuggestedName: String?
  @State private var insecure = false
  @State private var showAdvanced = false

  var body: some View {
    VStack(spacing: 0) {
      Text(L10n.text("Clone Image"))
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()

      Divider()

      Form {
        Section(L10n.text("Image Reference")) {
          TextField(
            L10n.text("Reference"),
            text: $reference,
            prompt: Text(L10n.text("e.g. ghcr.io/cirruslabs/ubuntu:latest"))
          )
        }

        if !cachedReferences.isEmpty {
          Section(L10n.text("Cached Images")) {
            ForEach(cachedReferences.prefix(4), id: \.self) { item in
              imageReferenceButton(item)
            }
          }
        }

        Section(L10n.text("Suggested Images")) {
          ForEach(commonImageReferences, id: \.self) { item in
            imageReferenceButton(item)
          }
        }

        Section(L10n.text("Local VM Name")) {
          TextField(L10n.text("Name"), text: $newName, prompt: Text(L10n.text("e.g. dev-machine")))

          if let issue = nameIssue {
            Label(L10n.text(issue), systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }

        Section {
          DisclosureGroup(L10n.text("Advanced Options"), isExpanded: $showAdvanced) {
            Toggle(L10n.text("Allow Insecure HTTP"), isOn: $insecure)
              .help(L10n.text("Only needed for private registries on an internal network"))
          }
        } footer: {
          Text(L10n.text("Clone downloads the image when needed and creates a runnable local VM."))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      CommandPreview(action: CommandAction(arguments: cloneArguments))
        .padding(.horizontal)
        .padding(.bottom, 12)

      Divider()

      HStack {
        Spacer()
        Button(L10n.text("Cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(L10n.text("Clone")) {
          onClone(reference, newName, insecure)
          dismiss()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canClone)
      }
      .padding()
    }
    .frame(width: 560, height: 560)
  }

  private var cloneArguments: [String] {
    var arguments = ["clone", reference, newName]
    if insecure {
      arguments.append("--insecure")
    }
    return arguments
  }

  private var nameIssue: String? {
    guard !newName.isEmpty else { return nil }
    if existingNames.contains(newName) {
      return "A VM with this name already exists."
    }
    if newName.contains("/") || newName.contains(":") {
      return "Names cannot contain slash or colon."
    }
    return nil
  }

  private var canClone: Bool {
    !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && nameIssue == nil
  }

  private func imageReferenceButton(_ item: String) -> some View {
    let isSelected = reference == item

    return Button {
      selectImageReference(item)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
          .imageScale(.medium)

        Text(item)
          .font(.system(.caption, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 7)
      .contentShape(.rect)
      .background(
        isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
        in: .rect(cornerRadius: 9)
      )
    }
    .buttonStyle(.plain)
  }

  private func selectImageReference(_ item: String) {
    let previousSuggestedName = lastSuggestedName
    let suggestion = suggestedName(from: item)

    reference = item

    if newName.isEmpty || newName == previousSuggestedName {
      newName = suggestion
      lastSuggestedName = suggestion
    } else {
      lastSuggestedName = nil
    }
  }

  private func suggestedName(from source: String) -> String {
    let lastComponent = source.split(separator: "/").last.map(String.init) ?? source
    let withoutTag = lastComponent.split(separator: ":").first.map(String.init) ?? lastComponent
    let base = withoutTag.isEmpty ? "clone" : withoutTag

    guard existingNames.contains(base) else { return base }

    for index in 2...99 where !existingNames.contains("\(base)-\(index)") {
      return "\(base)-\(index)"
    }
    return base
  }
}

/// Secondary registry flow: cache an OCI image locally without creating a VM.
struct PullImageSheet: View {
  let onPull: (String, Bool) -> Void

  @Environment(\.dismiss) private var dismiss

  @State private var reference = ""
  @State private var insecure = false
  @State private var showAdvanced = false

  var body: some View {
    VStack(spacing: 0) {
      Text(L10n.text("Cache Image"))
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()

      Divider()

      Form {
        Section(L10n.text("Image Reference")) {
          TextField(
            L10n.text("Reference"),
            text: $reference,
            prompt: Text(L10n.text("e.g. ghcr.io/cirruslabs/ubuntu:latest"))
          )
          .onSubmit { commitIfValid() }
        }

        Section(L10n.text("Suggested Images")) {
          ForEach(commonImageReferences, id: \.self) { item in
            suggestedImageButton(item)
          }
        }

        Section {
          DisclosureGroup(L10n.text("Advanced Options"), isExpanded: $showAdvanced) {
            Toggle(L10n.text("Allow Insecure HTTP"), isOn: $insecure)
          }
        } footer: {
          Text(L10n.text("Caching runs tart pull only. It does not create a runnable local VM."))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      CommandPreview(action: CommandAction(arguments: pullArguments))
        .padding(.horizontal)
        .padding(.bottom, 12)

      Divider()

      HStack {
        Spacer()
        Button(L10n.text("Cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(L10n.text("Cache")) { commitIfValid() }
          .keyboardShortcut(.defaultAction)
          .disabled(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
      .padding()
    }
    .frame(width: 540, height: 470)
  }

  private func suggestedImageButton(_ item: String) -> some View {
    let isSelected = reference == item

    return Button {
      reference = item
    } label: {
      HStack(spacing: 10) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
          .imageScale(.medium)

        Text(item)
          .font(.system(.caption, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)

        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 7)
      .contentShape(.rect)
      .background(
        isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
        in: .rect(cornerRadius: 9)
      )
    }
    .buttonStyle(.plain)
  }

  private var pullArguments: [String] {
    var arguments = ["pull", reference]
    if insecure {
      arguments.append("--insecure")
    }
    return arguments
  }

  private func commitIfValid() {
    let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    onPull(trimmed, insecure)
    dismiss()
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

      CommandPreview(action: registryAction)
        .padding(.horizontal)
        .padding(.bottom, 12)

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

  private var registryAction: CommandAction {
    switch mode {
    case .logout:
      return CommandAction(arguments: ["logout", host])
    case .login:
      var arguments = ["login", host, "--username", username, "--password-stdin"]
      if insecure { arguments.append("--insecure") }
      if !validate { arguments.append("--no-validate") }
      return CommandAction(arguments: arguments)
    }
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
