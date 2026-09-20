import Foundation

/// `tart prune` 的清理目标。
public enum PruneTarget: String, Sendable, CaseIterable {
  /// OCI 镜像缓存和 IPSW 缓存。
  case caches
  /// 本地虚拟机。危险得多——删的是真正的虚拟机，不是可重新下载的缓存。
  case vms

  public var displayName: String {
    switch self {
    case .caches: "Image and Installer Caches"
    case .vms: "Local VMs"
    }
  }

  public var isDestructive: Bool { self == .vms }
}

extension TartClient {
  // MARK: - 导入导出

  /// 把虚拟机导出成单个文件。
  ///
  /// 返回流：虚拟机有几十 GB，导出要写很久。
  public func exportAction(name: String, to path: String?) -> CommandAction {
    var arguments = ["export", name]
    if let path, !path.isEmpty {
      arguments.append(path)
    }
    return CommandAction(arguments: arguments)
  }

  public func export(name: String, to path: String?) -> AsyncThrowingStream<CommandEvent, any Error> {
    stream(exportAction(name: name, to: path))
  }

  public func importAction(from path: String, name: String) -> CommandAction {
    CommandAction(arguments: ["import", path, name])
  }

  /// 从导出文件恢复虚拟机。
  public func importVM(from path: String, name: String) -> AsyncThrowingStream<CommandEvent, any Error> {
    stream(importAction(from: path, name: name))
  }

  // MARK: - 清理

  /// 清理缓存或虚拟机。
  ///
  /// - Important: tart 没有提供 dry-run，这个命令一旦执行就会真的删除。
  ///   调用方必须先用 `PrunePlanner` 给用户看清楚将影响什么。
  /// - Parameters:
  ///   - olderThanDays: 删除超过 n 天未访问的条目。
  ///   - spaceBudgetGB: 按最近访问顺序保留，把总占用压到 n GB 以内。
  public func pruneAction(
    target: PruneTarget = .caches,
    olderThanDays: UInt? = nil,
    spaceBudgetGB: UInt? = nil
  ) -> CommandAction {
    var arguments = ["prune", "--entries", target.rawValue]

    if let olderThanDays {
      arguments += ["--older-than", String(olderThanDays)]
    }
    if let spaceBudgetGB {
      arguments += ["--space-budget", String(spaceBudgetGB)]
    }

    return CommandAction(arguments: arguments)
  }

  @discardableResult
  public func prune(
    target: PruneTarget = .caches,
    olderThanDays: UInt? = nil,
    spaceBudgetGB: UInt? = nil
  ) async throws -> CommandResult {
    guard olderThanDays != nil || spaceBudgetGB != nil else {
      throw TartError.commandFailed(
        command: ["prune"],
        exitCode: 1,
        stderr: "At least one prune criterion is required."
      )
    }

    return try await runChecked(pruneAction(
      target: target,
      olderThanDays: olderThanDays,
      spaceBudgetGB: spaceBudgetGB
    ))
  }

  // MARK: - 在虚拟机内执行命令

  /// 在运行中的虚拟机里执行命令并取回输出。
  ///
  /// 非交互式：不接标准输入、不分配伪终端。需要虚拟机内安装并运行
  /// [tart-guest-agent](https://github.com/cirruslabs/tart-guest-agent)。
  ///
  /// - Returns: 命令的输出和退出码。注意退出码来自虚拟机内的命令，
  ///   非零不代表 tart 本身失败，所以这里不抛错，由调用方判断。
  public func execAction(name: String, command: [String]) -> CommandAction {
    CommandAction(arguments: ["exec", name] + command)
  }

  public func exec(name: String, command: [String]) async throws -> CommandResult {
    guard !command.isEmpty else {
      throw TartError.commandFailed(
        command: ["exec", name],
        exitCode: 1,
        stderr: "No command was provided."
      )
    }

    // 不加 -i 和 -t：交互式需要接管标准输入和 PTY，那是另一套机制。
    return try await executor.run(execAction(name: name, command: command).arguments, stdin: nil)
  }
}

// MARK: - 清理预览

/// 预测 `tart prune` 会删掉哪些条目。
///
/// tart 不提供 dry-run，所以这里复刻它的选择逻辑（见 tart 的 `Commands/Prune.swift`）：
/// 按最后访问时间过滤，或按最近访问顺序保留、逐个判断剩余预算。
///
/// - Important: 预览**不完整**。`caches` 目标同时包含 IPSW 安装包缓存，
///   而 `tart list` 只列出 OCI 镜像，所以 IPSW 那部分无从得知。
///   界面上必须如实告知用户这一点，不能让人以为看到的就是全部。
public enum PrunePlanner {
  /// 一条预计会被删除的条目。
  public struct Candidate: Sendable, Hashable, Identifiable {
    public let name: String
    public let sizeGB: Int
    public let accessedAt: Date

    public var id: String { name }
  }

  public struct Plan: Sendable {
    public let candidates: [Candidate]
    /// 预计释放的空间。
    public let reclaimedGB: Int
    /// 预览是否可能不完整（存在看不到的 IPSW 缓存）。
    public let mayBeIncomplete: Bool

    public var isEmpty: Bool { candidates.isEmpty }
  }

  /// 根据条件算出将被删除的条目。
  ///
  /// - Parameter entries: 候选条目。调用方应当按 target 传入对应的集合
  ///   （caches 传 OCI 条目，vms 传本地虚拟机）。
  public static func plan(
    entries: [VMListEntry],
    target: PruneTarget,
    olderThanDays: UInt?,
    spaceBudgetGB: UInt?,
    now: Date = Date()
  ) -> Plan {
    var doomed: Set<String> = []

    if let olderThanDays {
      let cutoff = now.addingTimeInterval(-Double(olderThanDays) * 86400)
      for entry in entries where entry.accessedAt <= cutoff {
        doomed.insert(entry.name)
      }
    }

    if let spaceBudgetGB {
      // 复刻 tart 的逻辑：最近访问的排在前面，逐个看剩余预算是否装得下。
      // 注意这不是「超出预算后全删」——一个大条目放不下被删掉后，
      // 后面的小条目仍可能被保留。
      var remaining = Int(spaceBudgetGB)
      for entry in entries.sorted(by: { $0.accessedAt > $1.accessedAt }) {
        if entry.allocatedSizeGB <= remaining {
          remaining -= entry.allocatedSizeGB
        } else {
          doomed.insert(entry.name)
        }
      }
    }

    let candidates = entries
      .filter { doomed.contains($0.name) }
      .map { Candidate(name: $0.name, sizeGB: $0.allocatedSizeGB, accessedAt: $0.accessedAt) }
      .sorted { $0.accessedAt < $1.accessedAt }

    return Plan(
      candidates: candidates,
      reclaimedGB: candidates.reduce(0) { $0 + $1.sizeGB },
      // 清理缓存时 IPSW 部分看不见，预览必然不完整。
      mayBeIncomplete: target == .caches
    )
  }
}
