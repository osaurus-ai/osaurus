//
//  OsaurusServer.swift
//  osaurus
//
//  Actor-owned NIO server lifecycle (start / stop).
//

import Foundation
import LocalAuthentication
import NIOCore
import NIOHTTP1
import NIOPosix

public actor OsaurusServer: Sendable {
    public struct Config: Sendable {
        public var host: String
        public var port: Int
        public var agentIndex: UInt32?
        public init(host: String = "127.0.0.1", port: Int = 1337, agentIndex: UInt32? = nil) {
            self.host = host
            self.port = port
            self.agentIndex = agentIndex
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

        let validator = Self.buildValidator(agentIndex: config.agentIndex)

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            configuration: serverConfiguration,
                            apiKeyValidator: validator,
                            eventLoop: channel.eventLoop
                        )
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
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                g.shutdownGracefully { _ in cont.resume() }
            }
            self.group = nil
        }
        print("[Osaurus] OsaurusServer stopped")
    }

    // MARK: - Validator Construction

    /// Build a validator from the current identity, whitelist, and revocation state.
    /// Falls back to `.empty` if the account doesn't exist yet.
    private static func buildValidator(agentIndex: UInt32?) -> APIKeyValidator {
        guard MasterKey.exists() else { return .empty }

        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300

        do {
            var masterKeyData = try MasterKey.getPrivateKey(context: context)
            defer {
                masterKeyData.withUnsafeMutableBytes { ptr in
                    if let base = ptr.baseAddress { memset(base, 0, ptr.count) }
                }
            }

            let masterAddress = try deriveOsaurusId(from: masterKeyData)
            let agentAddress: OsaurusID =
                if let idx = agentIndex {
                    try AgentKey.deriveAddress(masterKey: masterKeyData, index: idx)
                } else {
                    masterAddress
                }

            return APIKeyValidator(
                agentAddress: agentAddress,
                masterAddress: masterAddress,
                effectiveWhitelist: WhitelistStore.shared.effectiveWhitelist(
                    forAgent: agentAddress,
                    masterAddress: masterAddress
                ),
                revocationSnapshot: RevocationStore.shared.snapshot(),
                hasKeys: !APIKeyManager.shared.listKeys().isEmpty
            )
        } catch {
            print("[Osaurus] Failed to build validator: \(error). Falling back to empty validator.")
            return .empty
        }
    }
}
