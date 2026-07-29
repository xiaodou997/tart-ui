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
  public func pull(
    remoteName: String,
    insecure: Bool = false,
    concurrency: UInt? = nil
  ) -> AsyncThrowingStream<CommandEvent, any Error> {
    var arguments = ["pull", remoteName]

    if insecure {
      arguments.append("--insecure")
    }
    if let concurrency {
      arguments += ["--concurrency", String(concurrency)]
    }

    return stream(arguments)
  }

  /// 把本地虚拟机推送到一个或多个远程引用。
  ///
  /// - Parameters:
  ///   - chunkSizeMB: 分块上传的块大小。各家仓库要求不同——ECR 只接受大于 5MB 的块，
  ///     GHCR 只接受小于 4MB 的，GCR 完全不支持分块。传 nil 用整体上传。
  ///   - populateCache: 顺带在本地缓存推送的镜像，占磁盘但省去之后重新拉取。
  public func push(
    localName: String,
    remoteNames: [String],
    insecure: Bool = false,
    concurrency: UInt? = nil,
    chunkSizeMB: Int? = nil,
    labels: [ImageLabel] = [],
    populateCache: Bool = false
  ) -> AsyncThrowingStream<CommandEvent, any Error> {
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

    return stream(arguments)
  }

  // MARK: - 登录

  /// 登录 OCI 仓库。
  ///
  /// 密码通过标准输入传给 tart（`--password-stdin`），**绝不作为命令行参数**——
  /// 命令行参数会出现在 `ps` 输出里，同机的任何进程都能看到。
  ///
  /// 凭据由 tart 自己存进钥匙串，TartPro 不保存也不缓存密码。
  ///
  /// - Parameter validate: 为 true 时 tart 会先验证凭据再保存。
  ///   关掉它可以在仓库暂时不可达时也先存下凭据。
  public func login(
    host: String,
    username: String,
    password: String,
    insecure: Bool = false,
    validate: Bool = true
  ) async throws {
    var arguments = ["login", host, "--username", username, "--password-stdin"]

    if insecure {
      arguments.append("--insecure")
    }
    if !validate {
      arguments.append("--no-validate")
    }

    let result = try await executor.run(arguments, stdin: Data(password.utf8))

    guard result.succeeded else {
      throw TartError.commandFailed(
        command: sanitized(arguments),
        exitCode: result.exitCode,
        stderr: result.stderr
      )
    }
  }

  /// 注销指定仓库的凭据。
  public func logout(host: String) async throws {
    try await runChecked(["logout", host])
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
