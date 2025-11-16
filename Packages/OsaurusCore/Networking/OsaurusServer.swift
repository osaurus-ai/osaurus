//
//  OsaurusServer.swift
//  osaurus
//
//  Introduces an actor-owned NIO server lifecycle (start/stop) to simplify control flow.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

public actor OsaurusServer: Sendable {
    public struct Config: Sendable {
        public var host: String
        public var port: Int
        public init(host: String = "127.0.0.1", port: Int = 1337) {
            self.host = host
            self.port = port
        }
    }

    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    public init() {}

    public func start(
        _ config: Config = .init(),
        serverConfiguration: ServerConfiguration = .default
    ) async throws {
        guard group == nil, channel == nil else { return }

        let threads = ProcessInfo.processInfo.activeProcessorCount
        let group = MultiThreadedEventLoopGroup(numberOfThreads: threads)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    // Inject configuration; ChatEngine is created per-connection by the handler.
                    channel.pipeline.addHandler(
                        HTTPHandler(configuration: serverConfiguration, eventLoop: channel.eventLoop)
                    )
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let ch = try await bootstrap.bind(host: config.host, port: config.port).get()
        self.group = group
        self.channel = ch
        print("[Osaurus] OsaurusServer started on http://\(config.host):\(config.port)")
    }

    public func stop(gracefully: Bool = true) async {
        if let ch = self.channel {
            _ = try? await ch.close()
            self.channel = nil
        }
        if let g = self.group {
            // Always use non-blocking shutdown in async context; ignore 'gracefully' fast-path for now
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                g.shutdownGracefully { _ in cont.resume() }
            }
            self.group = nil
        }
        print("[Osaurus] OsaurusServer stopped")
    }
}
