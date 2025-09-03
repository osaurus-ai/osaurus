//
//  Router.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Foundation
import NIOHTTP1
import NIOCore
import IkigaJSON

/// Simple routing logic for HTTP requests
public struct Router {
    /// Channel context for async operations (set by HTTPHandler)
    var context: ChannelHandlerContext?
    weak var handler: HTTPHandler?
    
    /// Create decoders per-request to ensure thread-safety
    private static func makeJSONDecoder() -> IkigaJSONDecoder { IkigaJSONDecoder() }

    /// Create encoders per-response to ensure thread-safety
    private func makeJSONEncoder() -> IkigaJSONEncoder { IkigaJSONEncoder() }
    
    init(context: ChannelHandlerContext? = nil, handler: HTTPHandler? = nil) {
        self.context = context
        self.handler = handler
    }
    /// Routes incoming HTTP requests to appropriate responses
    /// - Parameters:
    ///   - method: HTTP method (GET, POST, etc.)
    ///   - path: URL path
    ///   - body: Request body data
    /// - Returns: Tuple containing status, headers, and response body
    public func route(method: String, path: String, body: Data = Data()) -> (status: HTTPResponseStatus, headers: [(String, String)], body: String) {

        let p = normalize(path)
        if method == "HEAD" { return headOkEndpoint() }

        switch (method, p) {
        case ("GET", "/health"):
            return healthEndpoint()
            
        case ("GET", "/"):
            return rootEndpoint()
            
        case ("GET", "/models"):
            return modelsEndpoint()

        case ("GET", "/tags"):
            return tagsEndpoint()
            
        case ("POST", "/chat/completions"):
            return chatCompletionsEndpoint(body: body, context: context, handler: handler)

        case ("POST", "/chat"):
            return chatEndpoint(body: body, context: context, handler: handler)
            
        default:
            return notFoundEndpoint()
        }
    }

    /// Overload that accepts a ByteBuffer body to enable zero-copy decoding
    public func route(method: String, path: String, bodyBuffer: ByteBuffer) -> (status: HTTPResponseStatus, headers: [(String, String)], body: String) {

        let p = normalize(path)
        if method == "HEAD" { return headOkEndpoint() }

        switch (method, p) {
        case ("GET", "/health"):
            return healthEndpoint()
        
        case ("GET", "/"):
            return rootEndpoint()
        
        case ("GET", "/models"):
            return modelsEndpoint()

        case ("GET", "/tags"):
            return tagsEndpoint()
            
        case ("POST", "/chat/completions"):
            return chatCompletionsEndpoint(bodyBuffer: bodyBuffer, context: context, handler: handler)

        case ("POST", "/chat"):
            return chatEndpoint(bodyBuffer: bodyBuffer, context: context, handler: handler)
            
        default:
            return notFoundEndpoint()
        }
    }
    
    // MARK: - Private Endpoints
    
    private func healthEndpoint() -> (HTTPResponseStatus, [(String, String)], String) {
        var obj = JSONObject()
        obj["status"] = "healthy"
        obj["timestamp"] = Date().ISO8601Format()
        return (.ok, [("Content-Type", "application/json; charset=utf-8")], obj.string)
    }
    
    private func rootEndpoint() -> (HTTPResponseStatus, [(String, String)], String) {
        return (.ok, [("Content-Type", "text/plain; charset=utf-8")], "Osaurus Server is running! 🦕")
    }
    
    private func notFoundEndpoint() -> (HTTPResponseStatus, [(String, String)], String) {
        return (.notFound, [("Content-Type", "text/plain; charset=utf-8")], "Not Found")
    }
    
    private func headOkEndpoint() -> (HTTPResponseStatus, [(String, String)], String) {
        return (.noContent, [("Content-Type", "text/plain; charset=utf-8")], "")
    }

    private func modelsEndpoint() -> (HTTPResponseStatus, [(String, String)], String) {
        let models = MLXService.getAvailableModels().map { modelName in
            OpenAIModel(from: modelName)
        }
        
        let response = ModelsResponse(data: models)
        
        if let json = encodeJSONString(response) {
            return (.ok, [("Content-Type", "application/json; charset=utf-8")], json)
        }
        return errorResponse(message: "Failed to encode models", statusCode: .internalServerError)
    }
    
    private func tagsEndpoint() -> (HTTPResponseStatus, [(String, String)], String) {
        let now = Date().ISO8601Format()
        let models = MLXService.getAvailableModels().map { modelName in
            var model = OpenAIModel(from: modelName)
            // Fields for "/tags" compatibility
            model.name = modelName
            model.model = modelName
            model.modified_at = now
            model.size = 0
            model.digest = ""
            model.details = ModelDetails(
              parent_model: "",
              format: "safetensors",
              family: "unknown",
              families: ["unknown"],
              parameter_size: "",
              quantization_level: ""
            )
            return model
        }
        
        let response: [String: [OpenAIModel]] = ["models": models]
        
        if let json = encodeJSONString(response) {
            return (.ok, [("Content-Type", "application/json; charset=utf-8")], json)
        }
        return errorResponse(message: "Failed to encode models", statusCode: .internalServerError)
    }
    
    private func chatCompletionsEndpoint(body: Data, context: ChannelHandlerContext?, handler: HTTPHandler?) -> (HTTPResponseStatus, [(String, String)], String) {
        let decoder = Self.makeJSONDecoder()
        guard let request = try? decoder.decode(ChatCompletionRequest.self, from: body) else {
            return errorResponse(message: "Invalid request format", statusCode: .badRequest)
        }
        
        // Async operations require context and handler
        guard let context = context, let handler = handler else {
            return errorResponse(message: "Server configuration error", statusCode: .internalServerError)
        }
        
        // Handle async generation without MainActor; writes will be marshaled to the event loop
        // Use detached task to avoid actor context propagation overhead
        Task.detached(priority: .userInitiated) {
            await AsyncHTTPHandler.shared.handleChatCompletion(
                request: request,
                context: context
            )
        }
        
        // Return empty response - actual response will be sent asynchronously
        return (.ok, [], "")
    }

    private func chatCompletionsEndpoint(bodyBuffer: ByteBuffer, context: ChannelHandlerContext?, handler: HTTPHandler?) -> (HTTPResponseStatus, [(String, String)], String) {
        // Decode directly from ByteBuffer to avoid extra Data copies
        let decoder = Self.makeJSONDecoder()
        guard let request = try? decoder.decode(ChatCompletionRequest.self, from: bodyBuffer) else {
            return errorResponse(message: "Invalid request format", statusCode: .badRequest)
        }

        guard let context = context, let handler = handler else {
            return errorResponse(message: "Server configuration error", statusCode: .internalServerError)
        }

        Task.detached(priority: .userInitiated) {
            await AsyncHTTPHandler.shared.handleChatCompletion(
                request: request,
                context: context
            )
        }

        return (.ok, [], "")
    }
    
    private func chatEndpoint(body: Data, context: ChannelHandlerContext?, handler: HTTPHandler?) -> (HTTPResponseStatus, [(String, String)], String) {
        let decoder = Self.makeJSONDecoder()
        guard let request = try? decoder.decode(ChatCompletionRequest.self, from: body) else {
            return errorResponse(message: "Invalid request format", statusCode: .badRequest)
        }
        
        guard let context = context, let handler = handler else {
            return errorResponse(message: "Server configuration error", statusCode: .internalServerError)
        }
        
        Task.detached(priority: .userInitiated) {
            await AsyncHTTPHandler.shared.handleChat(
                request: request,
                context: context
            )
        }
        
        return (.ok, [], "")
    }

    private func chatEndpoint(bodyBuffer: ByteBuffer, context: ChannelHandlerContext?, handler: HTTPHandler?) -> (HTTPResponseStatus, [(String, String)], String) {
        let decoder = Self.makeJSONDecoder()
        guard let request = try? decoder.decode(ChatCompletionRequest.self, from: bodyBuffer) else {
            return errorResponse(message: "Invalid request format", statusCode: .badRequest)
        }

        guard let context = context, let handler = handler else {
            return errorResponse(message: "Server configuration error", statusCode: .internalServerError)
        }

        Task.detached(priority: .userInitiated) {
            await AsyncHTTPHandler.shared.handleChat(
                request: request,
                context: context
            )
        }

        return (.ok, [], "")
    }
    
    private func errorResponse(message: String, statusCode: HTTPResponseStatus) -> (HTTPResponseStatus, [(String, String)], String) {
        let error = OpenAIError(
            error: OpenAIError.ErrorDetail(
                message: message,
                type: "invalid_request_error",
                param: nil,
                code: nil
            )
        )
        
        if let json = encodeJSONString(error) {
            return (statusCode, [("Content-Type", "application/json; charset=utf-8")], json)
        }
        return (statusCode, [("Content-Type", "application/json; charset=utf-8")], "{\"error\":{\"message\":\"Internal error\"}}")
    }

    // MARK: - Helpers
    private func encodeJSONString<T: Encodable>(_ value: T) -> String? {
        let encoder = makeJSONEncoder()
        var buffer = ByteBufferAllocator().buffer(capacity: 1024)
        do {
            try encoder.encodeAndWrite(value, into: &buffer)
            return buffer.readString(length: buffer.readableBytes)
        } catch {
            return nil
        }
    }

    // Normalize common provider prefixes so we cover /, /v1, /api, /v1/api
    private func normalize(_ path: String) -> String {
        func stripPrefix(_ prefix: String, from s: String) -> String? {
            if s == prefix { return "/" }
            if s.hasPrefix(prefix + "/") {
                let idx = s.index(s.startIndex, offsetBy: prefix.count)
                let rest = String(s[idx...])
                return rest.isEmpty ? "/" : rest
            }
            return nil
        }
        // Try in most-specific order
        if let r = stripPrefix("/v1/api", from: path) { return r }
        if let r = stripPrefix("/api", from: path) { return r }
        if let r = stripPrefix("/v1", from: path) { return r }
        return path
    }
}
