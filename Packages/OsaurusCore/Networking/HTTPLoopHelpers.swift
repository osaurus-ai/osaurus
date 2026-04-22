//
//  HTTPLoopHelpers.swift
//  osaurus
//
//  Pure helpers shared by every `HTTPHandler` route extension. None of
//  these touch handler-instance state — they are extracted out of
//  `HTTPHandler.swift` so the handler file can stay focused on the
//  `ChannelInboundHandler` lifecycle and the route-dispatch chain.
//

import Foundation
import NIOCore
import NIOHTTP1

extension HTTPHandler {

    /// Build a `hop` closure that bounces the supplied block onto the
    /// channel's event loop, no-oping when the channel is no longer
    /// active. Every per-request `Task` captures `let hop = makeHop(...)`
    /// once and uses it to write back to the wire safely.
    static func makeHop(
        channel: Channel,
        loop: EventLoop
    ) -> (@escaping @Sendable () -> Void) -> Void {
        { block in
            guard channel.isActive else { return }
            if loop.inEventLoop { block() } else { loop.execute { block() } }
        }
    }

    /// Tiny mutable Bool box that satisfies Sendable for use across the
    /// streaming `Task` and the hop-dispatched closures inside it. Reads
    /// and writes happen exclusively on the channel's event loop, so the
    /// `@unchecked` is sound (NIO's loop confinement is the synchronizer).
    final class AtomicBoolBox: @unchecked Sendable {
        var value: Bool = false
    }

    /// Build an OpenAI-style short id `prefix-XXXX...` from a fresh UUID
    /// with hyphens stripped. The default `length` of 24 matches what
    /// OpenAI assigns to `tool_calls.id` / Anthropic `toolu_`/`msg_` ids.
    /// The shorter `length: 12` form is the conventional `chatcmpl-` /
    /// `resp_` shape.
    @inline(__always)
    static func shortId(prefix: String, length: Int = 24) -> String {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        return prefix + String(raw.prefix(length))
    }

    /// Iterate `body` in fixed-size character chunks, invoking `emit` per
    /// chunk. Used by every tool-call writer to chunk the JSON arguments
    /// payload onto the wire one OpenAI-/Anthropic-/OpenResponses-shaped
    /// delta at a time.
    @inline(__always)
    static func forEachStringChunk(
        _ body: String,
        size: Int,
        _ emit: (String) -> Void
    ) {
        var i = body.startIndex
        while i < body.endIndex {
            let next = body.index(i, offsetBy: size, limitedBy: body.endIndex) ?? body.endIndex
            emit(String(body[i ..< next]))
            i = next
        }
    }

    /// Write a single-shot JSON response (non-streaming) and close the
    /// connection. Centralizes the boilerplate around `Content-Type` /
    /// `Content-Length` / `Connection: close` so each non-streaming
    /// catch site stays one line. The `hop` closure dispatches onto the
    /// channel's event loop and must accept a `@Sendable` body because
    /// we cross from the request `Task` back into the loop.
    static func writeJSONResponse(
        body: String,
        cors: [(String, String)],
        head: HTTPRequestHead,
        ctx: NIOLoopBound<ChannelHandlerContext>,
        hop: (@escaping @Sendable () -> Void) -> Void
    ) {
        var headers: [(String, String)] = [("Content-Type", "application/json")]
        headers.append(contentsOf: cors)
        let headersCopy = headers
        hop {
            var responseHead = HTTPResponseHead(version: head.version, status: .ok)
            var buffer = ctx.value.channel.allocator.buffer(capacity: body.utf8.count)
            buffer.writeString(body)
            var nioHeaders = HTTPHeaders()
            for (name, value) in headersCopy { nioHeaders.add(name: name, value: value) }
            nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
            nioHeaders.add(name: "Connection", value: "close")
            responseHead.headers = nioHeaders
            let c = ctx.value
            c.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
            c.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            c.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil as HTTPHeaders?))).whenComplete { _ in
                ctx.value.close(promise: nil)
            }
        }
    }
}
