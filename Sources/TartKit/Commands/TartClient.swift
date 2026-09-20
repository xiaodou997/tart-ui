import Foundation

/// TartKit 的对外主入口。
///
/// 每个方法对应一条 tart 子命令。这一层只做三件事：
/// 拼参数、执行、把输出解码成类型化结果——不含任何 UI 或状态管理逻辑。
public struct TartClient: Sendable {
  /// 对同模块的扩展可见，registry 等命令需要直接用它传 stdin。
  let executor: any TartExecuting

  public init(executor: any TartExecuting) {
    self.executor = executor
  }

  /// 用默认的二进制探测逻辑构造。
  public init(userOverride: String? = nil, locator: TartLocator = TartLocator()) throws {
    let runtime = try locator.resolve(userOverride: userOverride)
    self.init(runtime: runtime)
  }

  /// 用已经解析好的运行时构造，供 UI 展示来源并避免重复探测。
  public init(runtime: TartRuntime, environment: [String: String]? = nil) {
    self.init(executor: TartExecutor(binaryURL: runtime.binaryURL, environment: environment))
  }

  /// 用明确的可执行文件构造，方便集成测试和高级用户指定路径。
  public init(binaryURL: URL, environment: [String: String]? = nil) {
    self.init(executor: TartExecutor(binaryURL: binaryURL, environment: environment))
  }

  // MARK: - 查询

  /// 列出虚拟机。
  ///
  /// - Parameter source: 传 nil 表示本地和 OCI 都要。
  public func list(source: VMSource? = nil) async throws -> [VMListEntry] {
    var arguments = ["list", "--format", "json"]
    if let source, source != .unknown {
      arguments += ["--source", source == .local ? "local" : "oci"]
    }
    return try await runDecoding([VMListEntry].self, arguments)
  }

  /// 读取单台虚拟机的配置详情。
  public func get(name: String) async throws -> VMDetails {
    try await runDecoding(VMDetails.self, ["get", name, "--format", "json"])
  }

  /// 查询虚拟机 IP。
  ///
  /// - Parameter waitSeconds: VM 刚启动时网络尚未就绪，tart 支持等待重试。
  public func ip(name: String, waitSeconds: UInt? = nil, resolver: IPResolver? = nil) async throws -> String {
    var arguments = ["ip", name]
    if let waitSeconds {
      arguments += ["--wait", String(waitSeconds)]
    }
    if let resolver {
      arguments += ["--resolver", resolver.rawValue]
    }
    let result = try await runChecked(arguments)
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 读取 tart 自身版本。也用作启动时的可用性自检。
  public func version() async throws -> String {
    let result = try await runChecked(["--version"])
    return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: - 生命周期

  /// 启动虚拟机，返回一条持续到进程退出的输出流。
  ///
  /// `tart run` 是长驻前台进程：它不会「启动完就返回」，而是一直运行到虚拟机关闭。
  /// 所以这里给的是流，调用方需要持有它直到结束，
  /// 释放流会连带终止子进程（见 `TartExecutor.stream`）。
  public func runAction(name: String, profile: RunProfile) -> CommandAction {
    CommandAction(arguments: profile.arguments(vmName: name))
  }

  public func runVM(name: String, profile: RunProfile) -> AsyncThrowingStream<CommandEvent, any Error> {
    stream(runAction(name: name, profile: profile))
  }

  /// 优雅关闭虚拟机。
  ///
  /// - Parameter timeout: 等待客户机自行关机的秒数，超时后强制断电。
  ///   传 nil 用 tart 的默认值。
  public func stopAction(name: String, timeout: UInt? = nil) -> CommandAction {
    var arguments = ["stop", name]
    if let timeout {
      arguments += ["--timeout", String(timeout)]
    }
    return CommandAction(arguments: arguments)
  }

  @discardableResult
  public func stop(name: String, timeout: UInt? = nil) async throws -> CommandResult {
    try await runChecked(stopAction(name: name, timeout: timeout))
  }

  /// 挂起虚拟机，把状态存到磁盘。
  ///
  /// 只对以 `--suspendable` 启动的虚拟机有效，否则 tart 会拒绝。
  public func suspendAction(name: String) -> CommandAction {
    CommandAction(arguments: ["suspend", name])
  }

  @discardableResult
  public func suspend(name: String) async throws -> CommandResult {
    try await runChecked(suspendAction(name: name))
  }

  // MARK: - 底层

  /// 流式执行命令，用于 pull / clone / create 这类长时操作。
  public func stream(_ action: CommandAction) -> AsyncThrowingStream<CommandEvent, any Error> {
    executor.stream(action.arguments)
  }

  public func stream(_ arguments: [String]) -> AsyncThrowingStream<CommandEvent, any Error> {
    stream(CommandAction(arguments: arguments))
  }

  /// 执行命令，非零退出码一律转成 `TartError.commandFailed`。
  @discardableResult
  public func runChecked(_ action: CommandAction) async throws -> CommandResult {
    try await runChecked(action.arguments)
  }

  @discardableResult
  public func runChecked(_ arguments: [String]) async throws -> CommandResult {
    let result: CommandResult
    do {
      result = try await executor.run(arguments)
    } catch is CancellationError {
      throw TartError.cancelled(command: arguments)
    }

    guard result.succeeded else {
      throw TartError.commandFailed(
        command: arguments,
        exitCode: result.exitCode,
        stderr: result.stderr
      )
    }
    return result
  }

  /// 执行命令并把 stdout 解码成指定类型。
  private func runDecoding<T: Decodable>(_ type: T.Type, _ arguments: [String]) async throws -> T {
    let result = try await runChecked(arguments)
    let data = Data(result.stdout.utf8)

    do {
      return try Self.decoder.decode(type, from: data)
    } catch {
      // 保留原始输出：上游改了 JSON schema 时，没有这段就无从下手。
      throw TartError.decodingFailed(
        command: arguments,
        raw: result.stdout,
        underlying: error
      )
    }
  }

  private static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }()
}

/// `tart ip` 的地址解析策略。取值对应 tart 的 `IPResolutionStrategy`。
public enum IPResolver: String, Sendable, CaseIterable {
  /// 解析宿主机的 DHCP 租约文件。最快也最可靠，但对桥接网络的 VM 无效。
  case dhcp
  /// 调用外部 `arp` 命令解析。支持桥接网络，但结果可能过期。
  case arp
  /// 走 guest agent 查询。需要 VM 内安装了 agent。
  case agent
}
