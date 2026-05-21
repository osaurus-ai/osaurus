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
    private final class LazyAPIKeyValidatorSnapshot: @unchecked Sendable {
        private let lock = NSLock()
        private let build: @Sendable () -> APIKeyValidator
        private var cached: APIKeyValidator?

        init(_ build: @escaping @Sendable () -> APIKeyValidator) {
            self.build = build
        }

        func value() -> APIKeyValidator {
            lock.lock()
            defer { lock.unlock() }
            if let cached { return cached }
            let validator = build()
            cached = validator
            return validator
        }
    }

    public struct Config: Sendable {
        public var host: String
        public var port: Int
        public var agentIndex: UInt32?
        public var trustLoopback: Bool
        public init(host: String = "127.0.0.1", port: Int = 1337, agentIndex: UInt32? = nil, trustLoopback: Bool = true)
        {
            self.host = host
            self.port = port
            self.agentIndex = agentIndex
            self.trustLoopback = trustLoopback
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

        let validatorSnapshot = LazyAPIKeyValidatorSnapshot {
            Self.buildValidator(agentIndex: config.agentIndex)
        }
        let trustLoopback = config.trustLoopback

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(
                        HTTPHandler(
                            configuration: serverConfiguration,
                            apiKeyValidatorProvider: { validatorSnapshot.value() },
                            eventLoop: channel.eventLoop,
                            trustLoopback: trustLoopback
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
        context.interactionNotAllowed = true

        do {
            var masterKeyData = try MasterKey.getPrivateKey(context: context)
            defer { masterKeyData.zeroOut() }

            let masterAddress = try deriveOsaurusId(from: masterKeyData)
            let agentAddress: OsaurusID =
                if let idx = agentIndex {
                    try AgentKey.deriveAddress(masterKey: masterKeyData, index: idx)
                } else {
                    masterAddress
                }
            APIKeyManager.shared.reload()

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
