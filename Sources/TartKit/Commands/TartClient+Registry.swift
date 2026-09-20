import Foundation

/// 推送镜像时附带的元数据标签。
public struct ImageLabel: Sendable, Hashable, Identifiable {
  public var id = UUID()
  public var key: String
  public var value: String

  public init(key: String, value: String) {
    self.key = key
    self.value = value
  }

  var argumentValue: String { "\(key)=\(value)" }
}

extension TartClient {
  // MARK: - 拉取与推送

  /// 从 OCI 仓库拉取镜像。
  ///
  /// 返回流：镜像动辄几十 GB。
  public func pullAction(
    remoteName: String,
    insecure: Bool = false,
    concurrency: UInt? = nil
  ) -> CommandAction {
    var arguments = ["pull", remoteName]

    if insecure {
      arguments.append("--insecure")
    }
    if let concurrency {
      arguments += ["--concurrency", String(concurrency)]
    }

    return CommandAction(arguments: arguments)
  }

  public func pull(
    remoteName: String,
    insecure: Bool = false,
    concurrency: UInt? = nil
  ) -> AsyncThrowingStream<CommandEvent, any Error> {
    stream(pullAction(remoteName: remoteName, insecure: insecure, concurrency: concurrency))
  }

  public func pushAction(
    localName: String,
    remoteNames: [String],
    insecure: Bool = false,
    concurrency: UInt? = nil,
    chunkSizeMB: Int? = nil,
    labels: [ImageLabel] = [],
    populateCache: Bool = false
  ) -> CommandAction {
    var arguments = ["push", localName] + remoteNames

    if insecure {
      arguments.append("--insecure")
    }
    if let concurrency {
      arguments += ["--concurrency", String(concurrency)]
    }
    if let chunkSizeMB {
      arguments += ["--chunk-size", String(chunkSizeMB)]
    }
    for label in labels where !label.key.isEmpty {
      arguments += ["--label", label.argumentValue]
    }
    if populateCache {
      arguments.append("--populate-cache")
    }

    return CommandAction(arguments: arguments)
  }

  public func push(
    localName: String,
    remoteNames: [String],
    insecure: Bool = false,
    concurrency: UInt? = nil,
    chunkSizeMB: Int? = nil,
    labels: [ImageLabel] = [],
    populateCache: Bool = false
  ) -> AsyncThrowingStream<CommandEvent, any Error> {
    stream(pushAction(
      localName: localName,
      remoteNames: remoteNames,
      insecure: insecure,
      concurrency: concurrency,
      chunkSizeMB: chunkSizeMB,
      labels: labels,
      populateCache: populateCache
    ))
  }

  // MARK: - 登录

  /// 登录 OCI 仓库。
  ///
  /// 密码通过标准输入传给 tart（`--password-stdin`），**绝不作为命令行参数**——
  /// 命令行参数会出现在 `ps` 输出里，同机的任何进程都能看到。
  ///
  /// 凭据由 tart 自己存进钥匙串，TartUI 不保存也不缓存密码。
  ///
  /// - Parameter validate: 为 true 时 tart 会先验证凭据再保存。
  ///   关掉它可以在仓库暂时不可达时也先存下凭据。
  public func loginAction(
    host: String,
    username: String,
    insecure: Bool = false,
    validate: Bool = true
  ) -> CommandAction {
    var arguments = ["login", host, "--username", username, "--password-stdin"]

    if insecure {
      arguments.append("--insecure")
    }
    if !validate {
      arguments.append("--no-validate")
    }

    return CommandAction(arguments: arguments)
  }

  @discardableResult
  public func login(
    host: String,
    username: String,
    password: String,
    insecure: Bool = false,
    validate: Bool = true
  ) async throws -> CommandResult {
    let action = loginAction(host: host, username: username, insecure: insecure, validate: validate)
    let result = try await executor.run(action.arguments, stdin: Data(password.utf8))

    guard result.succeeded else {
      throw TartError.commandFailed(
        command: sanitized(action.arguments),
        exitCode: result.exitCode,
        stderr: result.stderr
      )
    }

    return result
  }

  public func logoutAction(host: String) -> CommandAction {
    CommandAction(arguments: ["logout", host])
  }

  /// 注销指定仓库的凭据。
  @discardableResult
  public func logout(host: String) async throws -> CommandResult {
    try await runChecked(logoutAction(host: host))
  }

  /// 去掉参数里可能敏感的部分，用于错误信息和日志。
  ///
  /// 密码本身走的是 stdin 不在参数里，但用户名也不该随手记进日志。
  private func sanitized(_ arguments: [String]) -> [String] {
    var result = arguments
    if let index = result.firstIndex(of: "--username"), index + 1 < result.count {
      result[index + 1] = "***"
    }
    return result
  }
}
