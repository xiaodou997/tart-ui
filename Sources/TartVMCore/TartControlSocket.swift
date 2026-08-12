import Foundation
import NIO
import NIOPosix
import Virtualization
import os.log

/// 客户机控制通道：在 `~/.tart/vms/<name>/control.sock` 上监听，把每个连接
/// 双向代理到客户机的 vsock 端口。
///
/// **这不是可选的调试功能。** 客户机里的 guest agent 依赖这条通道；宿主不
/// 监听时，客户机会在进入桌面后每隔十几秒重启一次。这一点是通过在上游
/// `tart run` 里单独关掉 ControlSocket 复现出来的——关掉之后，上游同样开始
/// 以完全相同的周期重启。
///
/// 逻辑与上游 `ControlSocket` 等价，但把虚拟机作为参数传入，而不是读取一个
/// 全局变量：`tart run` 一个进程只跑一台虚拟机，TartUI 要同时跑多台。
actor TartControlSocket {
  private let socketURL: URL
  private let vmPort: UInt32
  private let connect: @Sendable (UInt32) async throws -> VZVirtioSocketConnection
  private let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  private let logger = os.Logger(subsystem: "com.tartui.control-socket", category: "network")

  init(
    socketURL: URL,
    vmPort: UInt32 = 8080,
    connect: @escaping @Sendable (UInt32) async throws -> VZVirtioSocketConnection
  ) {
    self.socketURL = socketURL
    self.vmPort = vmPort
    self.connect = connect
  }

  func run() async throws {
    // 上一次运行残留的 socket 文件会让 bind 报 "address already in use"。
    try? FileManager.default.removeItem(at: socketURL)

    // Unix domain socket 的路径上限是 104 字节，虚拟机目录路径很容易超。
    // 上游的做法是切到虚拟机目录再用相对路径 bind，这里照做。
    if let baseURL = socketURL.baseURL {
      FileManager.default.changeCurrentDirectoryPath(baseURL.path())
    }

    let server = try await ServerBootstrap(group: eventLoopGroup)
      .bind(unixDomainSocketPath: socketURL.relativePath) { channel in
        channel.eventLoop.makeCompletedFuture {
          try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
        }
      }

    try await withThrowingDiscardingTaskGroup { group in
      try await server.executeThenClose { inbound in
        for try await client in inbound {
          group.addTask { try await self.proxy(client) }
        }
      }
    }
  }

  private func proxy(_ client: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async throws {
    try await client.executeThenClose { clientInbound, clientOutbound in
      do {
        let vmConnection = try await connect(vmPort)

        let vmChannel = try await ClientBootstrap(group: eventLoopGroup)
          .withConnectedSocket(vmConnection.fileDescriptor) { channel in
            channel.eventLoop.makeCompletedFuture {
              try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: channel)
            }
          }

        try await vmChannel.executeThenClose { vmInbound, vmOutbound in
          try await withThrowingDiscardingTaskGroup { group in
            group.addTask {
              for try await message in clientInbound { try await vmOutbound.write(message) }
            }
            group.addTask {
              for try await message in vmInbound { try await clientOutbound.write(message) }
            }
          }
        }
      } catch {
        logger.error("control socket connection failed: \(error)")
      }
    }
  }
}
