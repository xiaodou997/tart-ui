import Foundation

/// TartKit 的对外主入口。
///
/// 每个方法对应一条 tart 子命令。这一层只做三件事：
/// 拼参数、执行、把输出解码成类型化结果——不含任何 UI 或状态管理逻辑。
public struct TartClient: Sendable {
  private let executor: any TartExecuting

  public init(executor: any TartExecuting) {
    self.executor = executor
  }

  /// 用默认的二进制探测逻辑构造。
  public init(userOverride: String? = nil, locator: TartLocator = TartLocator()) throws {
    let binaryURL = try locator.locate(userOverride: userOverride)
    self.init(executor: TartExecutor(binaryURL: binaryURL))
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

  // MARK: - 底层

  /// 执行命令，非零退出码一律转成 `TartError.commandFailed`。
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
