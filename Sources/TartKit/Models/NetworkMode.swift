import Foundation

/// 虚拟机的网络模式。
///
/// tart 的 `--net-bridged` / `--net-softnet` / `--net-host` 是互斥的，
/// 用枚举而不是几个并列的 Bool，让互斥性由类型系统保证——
/// 否则界面上很容易拼出同时带两个网络标志的非法命令。
public enum NetworkMode: Codable, Sendable, Hashable {
  /// 默认的共享（NAT）网络。不传任何网络参数。
  case shared

  /// 桥接到宿主机的某个网络接口。
  case bridged(interface: String)

  /// Softnet 软件网络，提供更强的隔离与端口转发。
  case softnet(SoftnetOptions)

  /// 仅限宿主机的网络。
  case hostOnly

  public static var `default`: NetworkMode { .shared }
}

/// Softnet 模式的细化配置。
///
/// 这几项在 tart 里都「隐含启用 --net-softnet」，所以收拢在这里，
/// 不作为独立开关。
public struct SoftnetOptions: Codable, Sendable, Hashable {
  /// 允许访问的 CIDR 列表，如 `192.168.0.0/24`。
  public var allowedCIDRs: [String]
  /// 禁止访问的 CIDR 列表。与 allow 冲突时 block 优先。
  public var blockedCIDRs: [String]
  /// 端口转发规则。
  public var exposedPorts: [PortForward]

  public init(
    allowedCIDRs: [String] = [],
    blockedCIDRs: [String] = [],
    exposedPorts: [PortForward] = []
  ) {
    self.allowedCIDRs = allowedCIDRs
    self.blockedCIDRs = blockedCIDRs
    self.exposedPorts = exposedPorts
  }
}

/// 一条端口转发规则：宿主机端口 → 虚拟机端口。
public struct PortForward: Codable, Sendable, Hashable, Identifiable {
  public var id = UUID()
  public var hostPort: Int
  public var guestPort: Int

  public init(hostPort: Int, guestPort: Int) {
    self.hostPort = hostPort
    self.guestPort = guestPort
  }

  /// tart 期望的 `外部端口:内部端口` 格式。
  public var argumentValue: String { "\(hostPort):\(guestPort)" }

  enum CodingKeys: String, CodingKey {
    case id, hostPort, guestPort
  }
}
