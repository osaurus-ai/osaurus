//
//  HTTPHandler.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// SwiftNIO HTTP request handler
final class HTTPHandler: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart
  typealias OutboundOut = HTTPServerResponsePart

  private let configuration: ServerConfiguration
  private var requestHead: HTTPRequestHead?
  private var requestBodyBuffer: ByteBuffer?
  private var context: ChannelHandlerContext?
  private var corsHeadersForCurrentRequest: [(String, String)] = []

  init(configuration: ServerConfiguration) {
    self.configuration = configuration
  }

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    self.context = context
    let part = self.unwrapInboundIn(data)

    switch part {
    case .head(let head):
      requestHead = head
      // Compute CORS headers for this request
      corsHeadersForCurrentRequest = computeCORSHeaders(for: head, isPreflight: false)
      // Pre-size body buffer if Content-Length is available
      if let lengthStr = head.headers.first(name: "Content-Length"), let length = Int(lengthStr),
        length > 0
      {
        requestBodyBuffer = context.channel.allocator.buffer(capacity: length)
      } else {
        requestBodyBuffer = context.channel.allocator.buffer(capacity: 0)
      }

    case .body(var buffer):
      // Collect body data directly into a ByteBuffer
      if requestBodyBuffer == nil {
        requestBodyBuffer = context.channel.allocator.buffer(capacity: buffer.readableBytes)
      }
      requestBodyBuffer!.writeBuffer(&buffer)

    case .end:
      guard let head = requestHead else {
        sendBadRequest(context: context)
        return
      }

      // Extract path without query parameters
      let pathOnly = extractPath(from: head.uri)

      // Handle CORS preflight (OPTIONS)
      if head.method == .OPTIONS {
        let cors = computeCORSHeaders(for: head, isPreflight: true)
        sendResponse(
          context: context,
          version: head.version,
          status: .noContent,
          headers: cors,
          body: ""
        )
        requestHead = nil
        requestBodyBuffer = nil
        return
      }

      // Create router with context
      let router = Router(context: context, handler: self)
      let response = router.route(
        method: head.method.rawValue, path: pathOnly,
        bodyBuffer: requestBodyBuffer ?? context.channel.allocator.buffer(capacity: 0))
      // Only send response if not handled asynchronously
      if !response.body.isEmpty || response.status != .ok {
        // Merge CORS headers into response
        var headersWithCORS = response.headers
        for (n, v) in corsHeadersForCurrentRequest { headersWithCORS.append((n, v)) }
        sendResponse(
          context: context,
          version: head.version,
          status: response.status,
          headers: headersWithCORS,
          body: response.body
        )
      }

      requestHead = nil
      requestBodyBuffer = nil
    }
  }

  // MARK: - Private Helpers

  private func extractPath(from uri: String) -> String {
    if let queryIndex = uri.firstIndex(of: "?") {
      return String(uri[..<queryIndex])
    }
    return uri
  }

  private func sendBadRequest(context: ChannelHandlerContext) {
    sendResponse(
      context: context,
      version: HTTPVersion(major: 1, minor: 1),
      status: .badRequest,
      headers: [("Content-Type", "text/plain; charset=utf-8")],
      body: "Bad Request"
    )
  }

  private func sendResponse(
    context: ChannelHandlerContext,
    version: HTTPVersion,
    status: HTTPResponseStatus,
    headers: [(String, String)],
    body: String
  ) {
    // Create response head
    var responseHead = HTTPResponseHead(version: version, status: status)

    // Create body buffer
    var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
    buffer.writeString(body)

    // Build headers
    var nioHeaders = HTTPHeaders()
    for (name, value) in headers {
      nioHeaders.add(name: name, value: value)
    }
    nioHeaders.add(name: "Content-Length", value: String(buffer.readableBytes))
    nioHeaders.add(name: "Connection", value: "close")
    responseHead.headers = nioHeaders

    // Send response
    context.write(self.wrapOutboundOut(.head(responseHead)), promise: nil)
    context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
    context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
      context.close(promise: nil)
    }
  }

  func errorCaught(context: ChannelHandlerContext, error: Error) {
    // Log and close the connection to avoid NIO debug preconditions crashing the app
    print("[Osaurus][NIO] errorCaught: \(error)")
    context.close(promise: nil)
  }

  // MARK: - CORS
  private func computeCORSHeaders(for head: HTTPRequestHead, isPreflight: Bool) -> [(
    String, String
  )] {
    guard !configuration.allowedOrigins.isEmpty else { return [] }
    let origin = head.headers.first(name: "Origin")
    var headers: [(String, String)] = []

    let allowsAny = configuration.allowedOrigins.contains("*")
    if allowsAny {
      headers.append(("Access-Control-Allow-Origin", "*"))
    } else if let origin,
      !origin.contains("\r"), !origin.contains("\n"),
      configuration.allowedOrigins.contains(origin)
    {
      headers.append(("Access-Control-Allow-Origin", origin))
      headers.append(("Vary", "Origin"))
    } else {
      // Not allowed; for preflight return no CORS headers which will cause browser to block
      return []
    }

    if isPreflight {
      // Methods
      let reqMethod = head.headers.first(name: "Access-Control-Request-Method")
      let allowMethods = sanitizeTokenList(reqMethod ?? "GET, POST, OPTIONS, HEAD")
      headers.append(("Access-Control-Allow-Methods", allowMethods))
      // Headers
      let reqHeaders = head.headers.first(name: "Access-Control-Request-Headers")
      let allowHeaders = sanitizeTokenList(reqHeaders ?? "Content-Type, Authorization")
      headers.append(("Access-Control-Allow-Headers", allowHeaders))
      headers.append(("Access-Control-Max-Age", "600"))
    }
    return headers
  }

  /// Allow only RFC7230 token characters plus comma and space for reflected header lists
  private func sanitizeTokenList(_ value: String) -> String {
    let allowedPunctuation = Set("!#$%&'*+-.^_`|~ ,")
    var result = String()
    result.reserveCapacity(value.count)
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0x30...0x39,  // 0-9
        0x41...0x5A,  // A-Z
        0x61...0x7A:  // a-z
        result.unicodeScalars.append(scalar)
      default:
        let ch = Character(scalar)
        if allowedPunctuation.contains(ch) {
          result.append(ch)
        }
      }
    }
    // Trim leading/trailing spaces and collapse runs of spaces around commas
    let collapsed = result.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }.joined(separator: ", ")
    return collapsed
  }

  /// Expose CORS headers for use by async writers
  var currentCORSHeaders: [(String, String)] { corsHeadersForCurrentRequest }
}
