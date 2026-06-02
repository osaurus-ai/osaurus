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
import os

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
                    channel.pipeline.addHandlers([
                        // Connection cap (first handler): a flood of idle-held
                        // sockets can't exhaust file descriptors / pin memory.
                        ConnectionLimitHandler(),
                        // Slow-loris / idle-hold defense: drop a connection that
                        // sends no bytes, accepts no writes, or sits fully idle
                        // past the budget. Long SSE streams emit periodic
                        // keepalive comments well inside the write window, so
                        // legitimate streaming is unaffected.
                        IdleStateHandler(
                            readTimeout: .seconds(60),
                            writeTimeout: .seconds(150),
                            allTimeout: .seconds(300)
                        ),
                        HTTPHandler(
                            configuration: serverConfiguration,
                            apiKeyValidatorProvider: { validatorSnapshot.value() },
                            eventLoop: channel.eventLoop,
                            trustLoopback: trustLoopback
                        ),
                    ])
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

    /// Stop the server.
    ///
    /// - Returns: `true` if the `EventLoopGroup` fully shut down (and was
    ///   released), `false` if the graceful shutdown exceeded its budget and
    ///   the group was deliberately left rooted to finish on its own. Callers
    ///   on the quit path use this to decide whether it is safe to drop their
    ///   reference to the actor (issue #860: dropping a still-running group
    ///   trips NIO's `EventLoopGroup is still running` precondition at exit).
    @discardableResult
    public func stop(gracefully: Bool = true) async -> Bool {
        if let ch = self.channel {
            _ = try? await ch.close()
            self.channel = nil
        }
        if let g = self.group {
            // `shutdownGracefully` waits for every in-flight child channel
            // to close. A long-lived SSE stream whose producer hasn't been
            // cancelled yet can keep one open, so on the quit path (where
            // callers pass `gracefully: false`) we cap the wait. On timeout
            // we DON'T null `group`: the shutdown is still in flight and the
            // group is rooted by the `ServerController` singleton, so it is
            // never deinitialized at process exit — that avoids the NIO
            // "EventLoopGroup is still running" precondition (issue #860)
            // while still unblocking quit.
            let budget: Double = gracefully ? 8.0 : 2.5
            let completed = await withCheckedContinuation {
                (cont: CheckedContinuation<Bool, Never>) in
                let resolved = OSAllocatedUnfairLock(initialState: false)
                @Sendable func claim() -> Bool {
                    resolved.withLock { done in
                        if done { return false }
                        done = true
                        return true
                    }
                }
                g.shutdownGracefully { _ in
                    if claim() { cont.resume(returning: true) }
                }
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(budget * 1_000_000_000))
                    if claim() { cont.resume(returning: false) }
                }
            }
            if completed {
                self.group = nil
                print("[Osaurus] OsaurusServer stopped")
                return true
            } else {
                print(
                    "[Osaurus] OsaurusServer graceful shutdown exceeded \(budget)s budget; proceeding (group left to finish)"
                )
                return false
            }
        } else {
            print("[Osaurus] OsaurusServer stopped")
            return true
        }
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

/// First handler in every child pipeline. Enforces a process-wide ceiling on
/// concurrently open connections so a flood of idle-held sockets (slow-loris,
/// connection-exhaustion DoS) can't run the descriptor table / memory up.
/// Accepted connections increment a shared atomic on `channelActive` and
/// decrement on `channelInactive`; the connection that pushes the live count
/// past the ceiling is closed immediately.
final class ConnectionLimitHandler: ChannelInboundHandler {
    typealias InboundIn = NIOAny
    typealias InboundOut = NIOAny

    /// Default ceiling. The server is loopback-first and gated downstream by
    /// `HTTPInferenceAdmission`; this is purely a coarse socket-flood backstop,
    /// set generously so normal multi-client / multi-tab use is never affected.
    static let maxConcurrentConnections = 512

    private static let liveCount = OSAllocatedUnfairLock(initialState: 0)

    /// Current number of open connections — surfaced for `/health`.
    static var currentCount: Int { liveCount.withLock { $0 } }

    private var counted = false

    func channelActive(context: ChannelHandlerContext) {
        let admitted = Self.liveCount.withLock { count -> Bool in
            guard count < Self.maxConcurrentConnections else { return false }
            count += 1
            return true
        }
        if admitted {
            counted = true
            context.fireChannelActive()
        } else {
            NSLog(
                "[Osaurus] Refusing connection — at max concurrent connections (%d)",
                Self.maxConcurrentConnections
            )
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if counted {
            counted = false
            Self.liveCount.withLock { $0 = max(0, $0 - 1) }
        }
        context.fireChannelInactive()
    }
}
