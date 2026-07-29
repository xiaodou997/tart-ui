import Foundation

/// 显示分辨率。tart 在 JSON 里用 `"1024x768"` 这种字符串表达。
public struct DisplayResolution: Codable, Sendable, Hashable, CustomStringConvertible {
  public let width: Int
  public let height: Int

  public init(width: Int, height: Int) {
    self.width = width
    self.height = height
  }

  public var description: String { "\(width)x\(height)" }

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard let parsed = DisplayResolution(parsing: raw) else {
      throw DecodingError.dataCorrupted(.init(
        codingPath: decoder.codingPath,
        debugDescription: "无法解析分辨率 '\(raw)'，期望 <宽>x<高> 格式"
      ))
    }
    self = parsed
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }

  public init?(parsing raw: String) {
    let parts = raw.lowercased().split(separator: "x")
    guard parts.count == 2,
          let width = Int(parts[0]),
          let height = Int(parts[1]),
          width > 0, height > 0
    else { return nil }
    self.init(width: width, height: height)
  }
}

/// `tart get <name> --format json` 的结果。
///
/// 注意它和 `tart list` 的 schema 并不一致——同名的 `Size` 在 list 里是整数 GB，
/// 在这里却是字符串（如 `"31.057"`）。两者必须分开建模，不能复用一个类型。
public struct VMDetails: Codable, Sendable, Hashable {
  public let cpuCount: Int
  /// 内存大小，单位 MB。
  public let memoryMB: Int
  public let display: DisplayResolution
  public let diskSizeGB: Int
  /// 实际占用空间（GB），tart 以字符串形式给出小数。
  public let allocatedSizeGB: Double
  public let os: String
  public let diskFormat: String
  public let state: VMState

  private let running: Bool

  public var isRunning: Bool { state == .running }

  /// 内存的 GB 表示，用于界面展示。
  public var memoryGB: Double { Double(memoryMB) / 1024 }

  enum CodingKeys: String, CodingKey {
    case cpuCount = "CPU"
    case memoryMB = "Memory"
    case display = "Display"
    case diskSizeGB = "Disk"
    case allocatedSizeGB = "Size"
    case os = "OS"
    case diskFormat = "DiskFormat"
    case state = "State"
    case running = "Running"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    cpuCount = try container.decode(Int.self, forKey: .cpuCount)
    memoryMB = try container.decode(Int.self, forKey: .memoryMB)
    display = try container.decode(DisplayResolution.self, forKey: .display)
    diskSizeGB = try container.decode(Int.self, forKey: .diskSizeGB)
    os = try container.decode(String.self, forKey: .os)
    diskFormat = try container.decode(String.self, forKey: .diskFormat)
    state = try container.decode(VMState.self, forKey: .state)
    running = try container.decodeIfPresent(Bool.self, forKey: .running) ?? (state == .running)

    // Size 是字符串形式的小数，这里转成 Double。
    let rawSize = try container.decode(String.self, forKey: .allocatedSizeGB)
    guard let size = Double(rawSize) else {
      throw DecodingError.dataCorrupted(.init(
        codingPath: container.codingPath + [CodingKeys.allocatedSizeGB],
        debugDescription: "无法把 '\(rawSize)' 解析为占用空间数值"
      ))
    }
    allocatedSizeGB = size
  }

  public init(
    cpuCount: Int,
    memoryMB: Int,
    display: DisplayResolution,
    diskSizeGB: Int,
    allocatedSizeGB: Double,
    os: String,
    diskFormat: String,
    state: VMState
  ) {
    self.cpuCount = cpuCount
    self.memoryMB = memoryMB
    self.display = display
    self.diskSizeGB = diskSizeGB
    self.allocatedSizeGB = allocatedSizeGB
    self.os = os
    self.diskFormat = diskFormat
    self.state = state
    self.running = state == .running
  }
}
