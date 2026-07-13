//
//  SandboxEgressProxy.swift
//  osaurus
//
//  Host-side filtering egress proxy for the sandbox VM's allowlist
//  network mode. When an agent's sandbox egress is domain-filtered, the
//  VM boots on a host-only vmnet (no NAT to the outside) and every
//  outbound connection must come through this proxy, which the guest
//  reaches at the vmnet gateway address.
//
//  Enforcement is per-connection and per-agent:
//  - The guest env carries `http_proxy`/`https_proxy` URLs of the form
//    `http://<bridge-token>:@<gateway>:<port>`, so each proxied request
//    arrives with `Proxy-Authorization: Basic base64(token:)`. The token
//    is the same per-agent bridge token the host API bridge uses —
//    identity is derived from it alone, never from anything the guest
//    claims.
//  - The requested hostname must match the agent's resolved allowlist
//    (`SandboxEgressPolicy.hostAllowed`); IP literals are rejected.
//  - The name is resolved on the host and every candidate address is
//    checked with `SandboxEgressPolicy.isBlockedAddress` before the
//    upstream connect, so a DNS-rebinding answer into loopback/RFC1918
//    space is refused even though the *name* was allowed. The connect
//    goes to the vetted address, not the name, to prevent a second
//    resolution from racing the check.
//
//  Supports HTTPS via CONNECT tunneling and plain HTTP via absolute-URI
//  forwarding (what curl/wget/apk send to an `http_proxy`).
//
//  Known limitation (documented in docs/SANDBOX.md): the guest can still
//  reach the vmnet gateway itself (this proxy and any host service bound
//  to that interface). Upstream nftables support is required to close
//  that from inside the guest.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

#if os(macOS)

    public actor SandboxEgressProxy {
        public static let shared = SandboxEgressProxy()

        /// Resolve a proxy-auth token to the allowlist it may reach.
        /// Returns `nil` for unknown tokens (connection is refused).
        public typealias AllowlistResolver = @Sendable (String) async -> [String]?

        private var group: MultiThreadedEventLoopGroup?
        private var channel: Channel?
        public private(set) var boundPort: Int?

        public init() {}

        public var isRunning: Bool { channel != nil }

        /// Start the proxy bound to `host` (the vmnet gateway address —
        /// never 0.0.0.0, which would expose the proxy to the LAN).
        /// Returns the bound port (`port == 0` picks an ephemeral one).
        @discardableResult
        public func start(
            host: String,
            port: Int = 0,
            resolver: @escaping AllowlistResolver
        ) async throws -> Int {
            if channel != nil { await stop() }

            let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 64)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(
                            ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                        )
                        try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder())
                        try channel.pipeline.syncOperations.addHandler(
                            SandboxEgressProxyHandler(resolver: resolver)
                        )
                    }
                }

            do {
                let ch = try await bootstrap.bind(host: host, port: port).get()
                self.group = group
                self.channel = ch
                self.boundPort = ch.localAddress?.port
                debugLog("[SandboxEgress] Proxy listening on \(host):\(boundPort ?? -1)")
                return boundPort ?? 0
            } catch {
                try? await group.shutdownGracefully()
                throw error
            }
        }

        public func stop() async {
            if let ch = channel {
                _ = try? await ch.close()
                channel = nil
            }
            if let g = group {
                try? await g.shutdownGracefully()
                group = nil
            }
            boundPort = nil
        }
    }

    // MARK: - Connection handler

    /// One instance per accepted connection. States:
    /// 1. awaiting request head → authorize + policy-check + upstream connect
    /// 2. relaying — HTTP handlers removed, raw bytes spliced both ways.
    final class SandboxEgressProxyHandler: ChannelInboundHandler, RemovableChannelHandler,
        @unchecked Sendable
    {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart

        private let resolver: SandboxEgressProxy.AllowlistResolver
        /// Body/tail bytes that arrive while the upstream connect is in
        /// flight (pipelined TLS client hello after CONNECT, or an HTTP
        /// request body). Flushed to upstream once the relay is glued.
        private var pendingUpstream: [ByteBuffer] = []
        private var upstream: Channel?
        private var connecting = false

        init(resolver: @escaping SandboxEgressProxy.AllowlistResolver) {
            self.resolver = resolver
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let part = unwrapInboundIn(data)
            switch part {
            case .head(let head):
                guard !connecting, upstream == nil else {
                    // A second request head mid-tunnel is a protocol
                    // violation; drop the connection.
                    context.close(promise: nil)
                    return
                }
                handleHead(context: context, head: head)
            case .body(let buffer):
                bufferOrForward(buffer)
            case .end:
                break
            }
        }

        /// After the relay is glued, the HTTP decoder is removed and raw
        /// bytes flow through `RawRelayHandler` instead — this handler
        /// only sees decoded parts during the setup phase.
        private func bufferOrForward(_ buffer: ByteBuffer) {
            if let upstream {
                upstream.writeAndFlush(buffer, promise: nil)
            } else {
                pendingUpstream.append(buffer)
            }
        }

        private func handleHead(context: ChannelHandlerContext, head: HTTPRequestHead) {
            guard let token = Self.extractProxyToken(headers: head.headers) else {
                respondAndClose(context: context, head: head, status: .proxyAuthenticationRequired)
                return
            }
            guard let target = Self.parseTarget(head: head) else {
                respondAndClose(context: context, head: head, status: .badRequest)
                return
            }

            connecting = true
            let eventLoop = context.eventLoop
            let contextBox = NIOLoopBound(context, eventLoop: eventLoop)
            let selfBox = NIOLoopBound(self, eventLoop: eventLoop)
            let resolver = self.resolver

            let setup = Task {
                guard let allowlist = await resolver(token) else {
                    return SetupResult.denied(.proxyAuthenticationRequired)
                }
                guard SandboxEgressPolicy.hostAllowed(target.host, allowlist: allowlist) else {
                    return SetupResult.denied(.forbidden)
                }
                // Host-side resolution + rebinding defense: connect to the
                // vetted address, never re-resolve the name.
                guard
                    let address = Self.resolveVettedAddress(
                        host: target.host,
                        port: target.port
                    )
                else {
                    return SetupResult.denied(.forbidden)
                }
                return SetupResult.allowed(address)
            }

            let promise = eventLoop.makePromise(of: SetupResult.self)
            promise.completeWithTask { await setup.value }
            promise.futureResult.whenSuccess { result in
                let context = contextBox.value
                let handler = selfBox.value
                switch result {
                case .denied(let status):
                    handler.respondAndClose(context: context, head: head, status: status)
                case .allowed(let address):
                    handler.connectUpstream(
                        context: context,
                        head: head,
                        target: target,
                        address: address
                    )
                }
            }
        }

        private enum SetupResult: Sendable {
            case allowed(SocketAddress)
            case denied(HTTPResponseStatus)
        }

        private func connectUpstream(
            context: ChannelHandlerContext,
            head: HTTPRequestHead,
            target: Target,
            address: SocketAddress
        ) {
            let eventLoop = context.eventLoop
            let contextBox = NIOLoopBound(context, eventLoop: eventLoop)
            let selfBox = NIOLoopBound(self, eventLoop: eventLoop)

            ClientBootstrap(group: eventLoop)
                .connectTimeout(.seconds(15))
                .connect(to: address)
                .whenComplete { result in
                    eventLoop.execute {
                        let context = contextBox.value
                        let handler = selfBox.value
                        switch result {
                        case .failure:
                            handler.respondAndClose(context: context, head: head, status: .badGateway)
                        case .success(let upstreamChannel):
                            handler.beginRelay(
                                context: context,
                                head: head,
                                target: target,
                                upstreamChannel: upstreamChannel
                            )
                        }
                    }
                }
        }

        private func beginRelay(
            context: ChannelHandlerContext,
            head: HTTPRequestHead,
            target: Target,
            upstreamChannel: Channel
        ) {
            self.upstream = upstreamChannel
            let clientChannel = context.channel

            if target.isConnect {
                // 200 through the still-installed encoder, then strip HTTP
                // handlers and splice raw bytes.
                let response = HTTPResponseHead(version: head.version, status: .custom(code: 200, reasonPhrase: "Connection Established"))
                context.write(wrapOutboundOut(.head(response)), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            } else {
                // Absolute-URI plain-HTTP: forward the rewritten request
                // head (origin-form path, proxy headers stripped) upstream
                // as raw bytes, then splice.
                var rewritten = head
                rewritten.uri = target.originFormURI
                var headers = head.headers
                headers.remove(name: "Proxy-Authorization")
                headers.remove(name: "Proxy-Connection")
                rewritten.headers = headers
                var buffer = upstreamChannel.allocator.buffer(capacity: 512)
                buffer.writeString("\(rewritten.method.rawValue) \(rewritten.uri) HTTP/1.1\r\n")
                for (name, value) in rewritten.headers {
                    buffer.writeString("\(name): \(value)\r\n")
                }
                buffer.writeString("\r\n")
                upstreamChannel.writeAndFlush(buffer, promise: nil)
            }

            for pending in pendingUpstream {
                upstreamChannel.writeAndFlush(pending, promise: nil)
            }
            pendingUpstream.removeAll()

            // Splice: upstream bytes -> client, client bytes -> upstream.
            // The HTTP decoder/encoder come out of the client pipeline so
            // TLS (or the HTTP response) flows through untouched.
            _ = upstreamChannel.pipeline.addHandler(
                RawRelayHandler(peer: clientChannel)
            )
            let pipeline = context.pipeline
            pipeline.context(handlerType: ByteToMessageHandler<HTTPRequestDecoder>.self)
                .whenSuccess { pipeline.removeHandler(context: $0, promise: nil) }
            pipeline.context(handlerType: HTTPResponseEncoder.self)
                .whenSuccess { pipeline.removeHandler(context: $0, promise: nil) }
            _ = pipeline.addHandler(RawRelayHandler(peer: upstreamChannel))
            pipeline.removeHandler(self, promise: nil)
        }

        private func respondAndClose(
            context: ChannelHandlerContext,
            head: HTTPRequestHead,
            status: HTTPResponseStatus
        ) {
            var headers = HTTPHeaders()
            headers.add(name: "Connection", value: "close")
            if status == .proxyAuthenticationRequired {
                headers.add(name: "Proxy-Authenticate", value: "Basic realm=\"osaurus-sandbox\"")
            }
            let response = HTTPResponseHead(version: head.version, status: status, headers: headers)
            context.write(wrapOutboundOut(.head(response)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                context.close(promise: nil)
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            upstream?.close(promise: nil)
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            upstream?.close(promise: nil)
            context.close(promise: nil)
        }

        // MARK: - Pure helpers (unit-tested without sockets)

        struct Target: Equatable {
            let host: String
            let port: Int
            let isConnect: Bool
            /// Path+query to use on the rewritten origin-form request line
            /// (absolute-URI HTTP only; empty for CONNECT).
            let originFormURI: String
        }

        /// Token from `Proxy-Authorization: Basic base64("<token>:")` (the
        /// form curl sends for `http://token:@host:port` proxy URLs).
        /// A `Bearer <token>` is accepted too for hand-rolled clients.
        static func extractProxyToken(headers: HTTPHeaders) -> String? {
            guard let raw = headers.first(name: "Proxy-Authorization") else { return nil }
            if raw.hasPrefix("Bearer ") {
                let token = String(raw.dropFirst("Bearer ".count))
                return token.isEmpty ? nil : token
            }
            guard raw.hasPrefix("Basic "),
                let decoded = Data(base64Encoded: String(raw.dropFirst("Basic ".count))),
                let pair = String(data: decoded, encoding: .utf8)
            else { return nil }
            // "<token>:" or "<token>:<ignored>"
            let token = pair.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
            return token.isEmpty ? nil : token
        }

        /// Parse the proxy target from a request head. CONNECT carries
        /// `host:port` in the URI; plain HTTP carries an absolute URI.
        static func parseTarget(head: HTTPRequestHead) -> Target? {
            if head.method == .CONNECT {
                let parts = head.uri.split(separator: ":", maxSplits: 1)
                guard parts.count == 2,
                    let port = Int(parts[1]), (1...65535).contains(port)
                else { return nil }
                let host = String(parts[0])
                guard !host.isEmpty else { return nil }
                return Target(host: host, port: port, isConnect: true, originFormURI: "")
            }
            // Absolute-URI plain HTTP (an https absolute URI through a
            // proxy is a protocol error — TLS must use CONNECT).
            guard let url = URL(string: head.uri),
                url.scheme == "http",
                let host = url.host, !host.isEmpty
            else { return nil }
            let port = url.port ?? 80
            var origin = url.path.isEmpty ? "/" : url.path
            if let query = url.query, !query.isEmpty {
                origin += "?\(query)"
            }
            return Target(host: host, port: port, isConnect: false, originFormURI: origin)
        }

        /// Resolve `host` and return a `SocketAddress` for the first
        /// candidate that is NOT a blocked (private/reserved/loopback)
        /// address. Returns `nil` when resolution fails or every candidate
        /// is blocked — the DNS-rebinding defense.
        static func resolveVettedAddress(host: String, port: Int) -> SocketAddress? {
            var hints = addrinfo()
            hints.ai_socktype = SOCK_STREAM
            hints.ai_family = AF_UNSPEC
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
                return nil
            }
            defer { freeaddrinfo(first) }
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let info = cursor {
                defer { cursor = info.pointee.ai_next }
                guard let addr = info.pointee.ai_addr else { continue }
                var textBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard
                    getnameinfo(
                        addr, info.pointee.ai_addrlen,
                        &textBuffer, socklen_t(textBuffer.count),
                        nil, 0,
                        NI_NUMERICHOST
                    ) == 0
                else { continue }
                let text = String(cString: textBuffer)
                guard !SandboxEgressPolicy.isBlockedAddress(text) else { continue }
                if let socketAddress = try? SocketAddress(ipAddress: text, port: port) {
                    return socketAddress
                }
            }
            return nil
        }
    }

    /// Forwards raw inbound bytes to `peer` and mirrors lifecycle: when
    /// either side closes, the other side is closed too.
    final class RawRelayHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer

        private let peer: Channel

        init(peer: Channel) {
            self.peer = peer
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            peer.close(promise: nil)
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: Error) {
            peer.close(promise: nil)
            context.close(promise: nil)
        }
    }

#endif
