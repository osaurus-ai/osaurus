//
//  SecureChannelResponseEncryptor.swift
//  osaurus
//
//  Outbound pipeline stage that encrypts HTTP responses for Secure Channel
//  calls. When `HTTPHandler` decrypts a `POST /secure/call` envelope it arms
//  this handler with the call's response sealer; every response part the
//  route handlers subsequently write — buffered JSON via `sendResponse`, or
//  streaming SSE via the response writers — is transparently sealed into
//  authenticated frames before reaching the HTTP encoder. Route handlers and
//  writers stay completely unaware of encryption.
//
//  Two shapes, chosen from the response's own Content-Type:
//
//  - Streaming (`text/event-stream`): the outer response stays an SSE stream,
//    but every `data:` payload is a sealed `SecureChannel.Frame` whose
//    plaintext is the original SSE bytes. `.end` emits one final empty frame
//    with the authenticated `fin` marker, so a client can distinguish a
//    completed stream from one silently truncated by a relay or middlebox.
//
//  - Buffered (anything else): head and body are held until `.end`, packed
//    into a `SecureChannel.InnerResponse` (status, content type, body), and
//    sent as a single `fin` frame in a 200 `application/json` envelope. The
//    real status code travels inside the ciphertext.
//
//  Sits between the HTTP encoder and `HTTPHandler`, same event loop; armed
//  state is plain mutable storage guarded by the loop.
//

import Foundation
import NIOCore
import NIOHTTP1

/// `@unchecked Sendable`: all mutable state (`sealer`, `mode`) is touched
/// exclusively on the channel's event loop — `arm` is called from
/// `HTTPHandler.channelRead` and `write` from outbound pipeline traversal,
/// both loop-confined. The class only crosses isolation as an opaque
/// reference held by `HTTPHandler`.
final class SecureChannelResponseEncryptor: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = HTTPServerResponsePart
    typealias OutboundOut = HTTPServerResponsePart

    /// Marker header on encrypted responses (diagnostic only; all integrity
    /// comes from the AEAD frames).
    static let markerHeaderName = "X-Osaurus-Secure-Channel"

    private enum Mode {
        case streaming
        case buffered(head: HTTPResponseHead, body: ByteBuffer?)
    }

    private var sealer: SecureResponseSealer?
    private var mode: Mode?

    /// Called by `HTTPHandler` (same event loop) after decrypting a
    /// `/secure/call` envelope. The next response written is encrypted.
    func arm(sealer: SecureResponseSealer) {
        self.sealer = sealer
        self.mode = nil
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard let sealer else {
            context.write(data, promise: promise)
            return
        }
        let part = unwrapOutboundIn(data)
        switch part {
        case .head(let head):
            let contentType = head.headers.first(name: "Content-Type") ?? ""
            if contentType.lowercased().hasPrefix("text/event-stream") {
                mode = .streaming
                var newHead = head
                newHead.headers.replaceOrAdd(name: Self.markerHeaderName, value: "1")
                context.write(wrapOutboundOut(.head(newHead)), promise: promise)
            } else {
                mode = .buffered(head: head, body: nil)
                promise?.succeed(())
            }

        case .body(let ioData):
            guard case .byteBuffer(var buffer) = ioData else {
                // File regions are never produced by Osaurus routes; pass
                // through rather than crash if that ever changes.
                context.write(data, promise: promise)
                return
            }
            switch mode {
            case .streaming:
                let plaintext = buffer.readData(length: buffer.readableBytes) ?? Data()
                writeFrame(sealer: sealer, plaintext: plaintext, fin: false, context: context, promise: promise)
            case .buffered(let head, var held):
                if held == nil {
                    held = buffer
                } else {
                    held?.writeBuffer(&buffer)
                }
                mode = .buffered(head: head, body: held)
                promise?.succeed(())
            case nil:
                // Body before head — malformed; pass through untouched.
                context.write(data, promise: promise)
            }

        case .end:
            switch mode {
            case .streaming:
                // Authenticated end-of-stream marker: an empty fin frame.
                writeFrame(sealer: sealer, plaintext: Data(), fin: true, context: context, promise: nil)
                finish()
                context.write(data, promise: promise)
            case .buffered(let head, let body):
                let bodyData = body.flatMap { buf -> Data? in
                    var copy = buf
                    return copy.readData(length: copy.readableBytes)
                }
                let inner = SecureChannel.InnerResponse(
                    status: Int(head.status.code),
                    contentType: head.headers.first(name: "Content-Type"),
                    body: bodyData?.base64urlEncoded
                )
                finish()
                do {
                    let plaintext = try JSONEncoder().encode(inner)
                    let frame = try sealer.seal(plaintext, fin: true)
                    let frameJSON = try JSONEncoder().encode(frame)

                    var newHead = HTTPResponseHead(version: head.version, status: .ok)
                    newHead.headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
                    newHead.headers.add(name: Self.markerHeaderName, value: "1")
                    newHead.headers.add(name: "Content-Length", value: String(frameJSON.count))
                    if let connection = head.headers.first(name: "Connection") {
                        newHead.headers.add(name: "Connection", value: connection)
                    }
                    var buffer = context.channel.allocator.buffer(capacity: frameJSON.count)
                    buffer.writeBytes(frameJSON)
                    context.write(wrapOutboundOut(.head(newHead)), promise: nil)
                    context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                    context.write(wrapOutboundOut(.end(nil)), promise: promise)
                } catch {
                    promise?.fail(error)
                    context.close(promise: nil)
                }
            case nil:
                finish()
                context.write(data, promise: promise)
            }
        }
    }

    private func writeFrame(
        sealer: SecureResponseSealer,
        plaintext: Data,
        fin: Bool,
        context: ChannelHandlerContext,
        promise: EventLoopPromise<Void>?
    ) {
        do {
            let frame = try sealer.seal(plaintext, fin: fin)
            let json = try JSONEncoder().encode(frame)
            var buffer = context.channel.allocator.buffer(capacity: json.count + 16)
            buffer.writeString("data: ")
            buffer.writeBytes(json)
            buffer.writeString("\n\n")
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        } catch {
            promise?.fail(error)
            context.close(promise: nil)
        }
    }

    private func finish() {
        sealer = nil
        mode = nil
    }
}
