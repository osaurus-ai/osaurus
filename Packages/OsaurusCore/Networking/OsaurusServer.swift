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
        /// Epoch the cached validator was built at. When the global epoch
        /// advances (key minted/revoked, whitelist/agent change), the cache is
        /// considered stale and rebuilt on next access.
        private var cachedEpoch: UInt64 = 0

        init(_ build: @escaping @Sendable () -> APIKeyValidator) {
            self.build = build
        }

        func value() -> APIKeyValidator {
            let epoch = APIKeyValidatorEpoch.shared.current()
            lock.lock()
            defer { lock.unlock() }
            if let cached, cachedEpoch == epoch { return cached }
            let validator = build()
            cached = validator
            cachedEpoch = epoch
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

    private var channel: Channel?
    /// Live child (per-connection) channels, tracked so `stop` can close
    /// them explicitly. The event-loop group is process-shared
    /// (`SharedEventLoopGroups.server`) and never shut down, so "stop the
    /// server" means "close the listener and its connections" — not "tear
    /// down loops". Per-start groups were the EMFILE crash (APPLE-MACOS-19T:
    /// nine accumulated 10-thread groups).
    private let childChannels = ChildChannelRegistry()

    public init() {}

    /// The port the server is actually bound to, or nil when stopped.
    /// Meaningful for callers that bind port 0 (ephemeral) — the eval
    /// harness does this so an in-process contract suite can never
    /// collide with a user's running Osaurus on 1337.
    public func boundPort() -> Int? {
        channel?.localAddress?.port
    }

    public func start(
        _ config: Config = .init(),
        serverConfiguration: ServerConfiguration = .default
    ) async throws {
        guard channel == nil else { return }

        let group = SharedEventLoopGroups.server
        let childChannels = self.childChannels

        let validatorSnapshot = LazyAPIKeyValidatorSnapshot {
            Self.buildValidator(agentIndex: config.agentIndex)
        }
        let trustLoopback = config.trustLoopback

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                childChannels.track(channel)
                return channel.pipeline.configureHTTPServerPipeline().flatMap {
                    // Outbound encryption stage for Secure Channel calls.
                    // Must sit between the HTTP encoder and HTTPHandler so
                    // every response part the routes write can be sealed.
                    let responseEncryptor = SecureChannelResponseEncryptor()
                    return channel.pipeline.addHandlers([
                        // Connection cap (first handler): a flood of idle-held
                        // sockets can't exhaust file descriptors / pin memory.
                        ConnectionLimitHandler(),
                        responseEncryptor,
                        // Slow-loris / idle-hold defense cannot use NIO idle
                        // timeouts on this pipeline: long local non-streaming
                        // model calls intentionally produce no response bytes
                        // until generation completes, and slow cold loads can
                        // exceed several minutes. ConnectionLimitHandler keeps
                        // idle-held sockets bounded without closing legitimate
                        // in-flight inference requests.
                        HTTPHandler(
                            configuration: serverConfiguration,
                            apiKeyValidatorProvider: { validatorSnapshot.value() },
                            eventLoop: channel.eventLoop,
                            trustLoopback: trustLoopback,
                            responseEncryptor: responseEncryptor
                        ),
                    ])
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        let ch = try await bootstrap.bind(host: config.host, port: config.port).get()
        self.channel = ch
        print("[Osaurus] OsaurusServer started on http://\(config.host):\(config.port)")
    }

    /// Stop the server: close the listener, then close the per-connection
    /// child channels. The event-loop group is process-shared and is never
    /// shut down here, so this cannot leak threads/descriptors across
    /// restarts (APPLE-MACOS-19T) and cannot trip NIO's "EventLoopGroup is
    /// still running" deinit precondition at exit (issue #860).
    ///
    /// - Parameter gracefully: when `true`, in-flight connections get up to
    ///   8 seconds to finish before being force-closed; the quit path passes
    ///   `false` for a bounded 1-second drain.
    /// - Returns: `true` always (kept for call-site compatibility — with a
    ///   shared group there is no longer a "shutdown still in flight" state
    ///   that requires keeping the actor rooted).
    @discardableResult
    public func stop(gracefully: Bool = true) async -> Bool {
        if let ch = self.channel {
            _ = try? await ch.close()
            self.channel = nil
        }
        // Give in-flight connections a bounded window to complete on their
        // own (an SSE stream mid-generation, a response mid-flush), then
        // force-close whatever remains. Closing is idempotent, so racing a
        // natural close is fine.
        let budget: Double = gracefully ? 8.0 : 1.0
        let deadline = Date().addingTimeInterval(budget)
        while !childChannels.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let remaining = childChannels.drain()
        if !remaining.isEmpty {
            print(
                "[Osaurus] OsaurusServer force-closing \(remaining.count) connection(s) after \(budget)s drain budget"
            )
            for ch in remaining {
                ch.close(promise: nil)
            }
        }
        print("[Osaurus] OsaurusServer stopped")
        return true
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

            // Accept tokens scoped to ANY of the user's agents so that
            // agent-scoped keys minted by `/pair` and `/pair-invite` (whose
            // `aud` is the agent's address, not the master's) validate. The
            // agent addresses come from the thread-safe `AgentIdentityRegistry`
            // (mirrored from `AgentManager`), so no extra key derivation is
            // needed here. When a specific `agentIndex` is requested
            // (single-agent server config), restrict to just that agent.
            var agentAddresses: Set<OsaurusID> = []
            if let idx = agentIndex {
                agentAddresses.insert(try AgentKey.deriveAddress(masterKey: masterKeyData, index: idx))
            } else {
                agentAddresses.formUnion(AgentIdentityRegistry.shared.currentAddresses())
            }
            // Always keep a non-empty set; the master address is implicitly
            // accepted by the validator regardless.
            if agentAddresses.isEmpty { agentAddresses.insert(masterAddress) }

            APIKeyManager.shared.reload()

            // The effective whitelist must cover every accepted agent so that
            // agent-signed keys (iss == agent address) pass the whitelist gate.
            var whitelist = WhitelistStore.shared.masterWhitelist()
            whitelist.insert(masterAddress.lowercased())
            for addr in agentAddresses {
                whitelist.formUnion(
                    WhitelistStore.shared.effectiveWhitelist(forAgent: addr, masterAddress: masterAddress)
                )
            }

            return APIKeyValidator(
                agentAddresses: agentAddresses,
                masterAddress: masterAddress,
                effectiveWhitelist: whitelist,
                revocationSnapshot: RevocationStore.shared.snapshot(),
                hasKeys: !APIKeyManager.shared.listKeys().isEmpty
            )
        } catch {
            print("[Osaurus] Failed to build validator: \(error). Falling back to empty validator.")
            return .empty
        }
    }
}

/// Tracks the live child (per-connection) channels of one server instance so
/// `stop` can drain and close them explicitly. Needed because the event-loop
/// group is process-shared: `shutdownGracefully` — which used to close
/// stragglers — is never called anymore.
final class ChildChannelRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: Channel] = [:]

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return channels.count
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return channels.isEmpty
    }

    func track(_ channel: Channel) {
        let id = ObjectIdentifier(channel)
        lock.lock()
        channels[id] = channel
        lock.unlock()
        channel.closeFuture.whenComplete { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.channels.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    /// Remove and return every tracked channel (they are about to be closed).
    func drain() -> [Channel] {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(channels.values)
        channels.removeAll()
        return all
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
