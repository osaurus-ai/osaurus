//
//  MCPProviderTool.swift
//  osaurus
//
//  Tool wrapper for remote MCP provider tools.
//

import Foundation
import ImageIO
import MCP
import UniformTypeIdentifiers

/// A tool provided by a remote MCP server
final class MCPProviderTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name: String
    let description: String
    let parameters: JSONValue?
    let requirements: [String]
    let defaultPermissionPolicy: ToolPermissionPolicy

    /// The provider ID this tool belongs to
    let providerId: UUID

    /// The provider name for display purposes
    let providerName: String

    /// Original MCP tool name (may differ from exposed name if prefixed)
    let mcpToolName: String

    /// Maximum length for remote MCP tool descriptions exposed to the model.
    /// Vendors often put parameter semantics and examples beyond 200 chars; 4000
    /// keeps the guardrail without stripping actionable detail.
    static let maxDescriptionLength = 4_000

    init(
        mcpTool: MCP.Tool,
        providerId: UUID,
        providerName: String,
        prefixWithProvider: Bool = true,
        reservedNames: Set<String> = []
    ) {
        self.providerId = providerId
        self.providerName = providerName
        self.mcpToolName = mcpTool.name

        if prefixWithProvider {
            self.name = Self.exposedName(
                providerId: providerId,
                providerName: providerName,
                mcpToolName: mcpTool.name,
                reservedNames: reservedNames
            )
        } else {
            self.name = mcpTool.name
        }

        let desc = mcpTool.description ?? "Tool from \(providerName)"
        self.description = Self.truncatedDescription(desc)

        // Convert MCP input schema to JSONValue
        self.parameters = Self.convertInputSchema(mcpTool.inputSchema)

        // MCP tools require network access
        self.requirements = ["network"]

        // Default to asking for permission since these are remote tools
        self.defaultPermissionPolicy = .ask
    }

    /// Sanitize a provider display name into a stable tool-name prefix segment.
    static func sanitizedProviderPrefix(from providerName: String) -> String {
        providerName
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Build the Osaurus-exposed tool name for an MCP tool, disambiguating when
    /// two providers normalize to the same prefix (e.g. "My Server" / "my-server").
    static func exposedName(
        providerId: UUID,
        providerName: String,
        mcpToolName: String,
        reservedNames: Set<String> = []
    ) -> String {
        let basePrefix = sanitizedProviderPrefix(from: providerName)
        let prefix = basePrefix.isEmpty ? "mcp" : basePrefix
        let candidate = sanitizeExposedToolName("\(prefix)_\(mcpToolName)")
        guard reservedNames.contains(candidate) else { return candidate }

        // Append a stable short id from the provider UUID so collisions can't
        // silently overwrite another provider's tool in the registry.
        let disambiguator = providerId.uuidString
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()
        return sanitizeExposedToolName("\(prefix)_\(disambiguator)_\(mcpToolName)")
    }

    /// Local copy of `ToolRegistry.sanitizeToolName` so prefix logic stays
    /// callable from this type's nonisolated initialiser path.
    private static func sanitizeExposedToolName(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw {
            if ch.isASCII, ch.isLetter || ch.isNumber || ch == "_" || ch == "-" {
                out.append(ch)
            } else {
                out.append("_")
            }
        }
        if out.isEmpty { out = "tool_unnamed" }
        if out.count > 64 { out = String(out.prefix(64)) }
        return out
    }

    static func truncatedDescription(_ raw: String) -> String {
        guard raw.count > maxDescriptionLength else { return raw }
        return String(raw.prefix(maxDescriptionLength)) + "..."
    }

    func execute(argumentsJSON: String) async throws -> String {
        // Delegate execution to MCPProviderManager
        return try await MCPProviderManager.shared.executeTool(
            providerId: providerId,
            toolName: mcpToolName,
            argumentsJSON: argumentsJSON,
            exposedToolName: name
        )
    }

    // MARK: - Schema Conversion

    /// Convert MCP Value schema to Osaurus JSONValue
    static func convertInputSchema(_ schema: MCP.Value?) -> JSONValue? {
        guard let schema = schema else {
            // Return a basic object schema if none provided
            return .object(["type": .string("object"), "properties": .object([:])])
        }
        // MCP no-arg tools may omit `properties`; fill it in at ingest so the
        // stored spec is valid for OpenAI-style tool validators.
        return convertMCPValue(schema).withEmptyPropertiesIfMissing
    }

    /// Convert MCP.Value to JSONValue recursively
    private static func convertMCPValue(_ value: MCP.Value) -> JSONValue {
        switch value {
        case .null:
            return .null
        case .bool(let b):
            return .bool(b)
        case .int(let i):
            return .number(Double(i))
        case .double(let d):
            return .number(d)
        case .string(let s):
            return .string(s)
        case .array(let arr):
            return .array(arr.map { convertMCPValue($0) })
        case .object(let obj):
            var dict: [String: JSONValue] = [:]
            for (key, val) in obj {
                dict[key] = convertMCPValue(val)
            }
            return .object(dict)
        case .data(_, let data):
            // Convert data to base64 string
            return .string(data.base64EncodedString())
        }
    }
}

// MARK: - MCP Value to Any Conversion (for tool execution)

extension MCPProviderTool {
    /// Convert JSON arguments string to MCP.Value dictionary.
    ///
    /// Empty / `{}` inputs are accepted as a legitimate "no arguments" call.
    /// Anything else that fails to parse as a JSON object — malformed JSON,
    /// non-object payloads, or the upstream serialization-error envelope
    /// emitted by `GenerationEventMapper.serializeArguments` when a tool
    /// call's arguments fail to JSON-encode — throws so the model receives
    /// a structured error instead of silently running with no arguments.
    static func convertArgumentsToMCPValues(_ argumentsJSON: String) throws -> [String: MCP.Value] {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "{}" { return [:] }

        guard let data = trimmed.data(using: .utf8) else {
            throw argumentError(code: 10, message: "Tool arguments are not valid UTF-8")
        }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw argumentError(
                code: 11,
                message:
                    "Tool arguments are not valid JSON: \(error.localizedDescription). Got: \(String(trimmed.prefix(200)))"
            )
        }

        guard let jsonObject = parsed as? [String: Any] else {
            throw argumentError(
                code: 12,
                message: "Tool arguments must be a JSON object, got \(type(of: parsed))"
            )
        }

        // The upstream accumulator's serialization-failure envelope must
        // surface as an error rather than be passed through as a bogus arg.
        if let err = jsonObject["_error"] as? String {
            throw argumentError(code: 13, message: "Upstream argument serialization failed: \(err)")
        }

        var result: [String: MCP.Value] = [:]
        for (key, value) in jsonObject {
            result[key] = try convertToMCPValue(value)
        }
        return result
    }

    private static func argumentError(code: Int, message: String) -> NSError {
        NSError(
            domain: "MCPProviderTool",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    /// Convert Foundation types to MCP.Value
    private static func convertToMCPValue(_ value: Any) throws -> MCP.Value {
        switch value {
        case let stringValue as String:
            return .string(stringValue)
        // JSONSerialization decodes every JSON number and boolean as NSNumber,
        // and Foundation's bridging lets both `NSNumber(value: 1) as? Bool`
        // and `NSNumber(value: 0) as? Bool` succeed. A plain `as Bool` case
        // ahead of `as Int` therefore turned the integers 0 / 1 into
        // `false` / `true`, so `{"offset": 1}` reached the MCP server as
        // `{"offset": true}` and was rejected by integer-typed parameters.
        // Use the CFBoolean type id to tell a real JSON boolean apart from a
        // number, and the CFNumber float flag to keep `1.0` a double.
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if CFNumberIsFloatType(number) {
                return .double(number.doubleValue)
            }
            return .int(number.intValue)
        case let boolValue as Bool:
            return .bool(boolValue)
        case let intValue as Int:
            return .int(intValue)
        case let doubleValue as Double:
            return .double(doubleValue)
        case let arrayValue as [Any]:
            let mcpArray = try arrayValue.map { try convertToMCPValue($0) }
            return .array(mcpArray)
        case let dictValue as [String: Any]:
            var mcpObject: [String: MCP.Value] = [:]
            for (k, v) in dictValue {
                mcpObject[k] = try convertToMCPValue(v)
            }
            return .object(mcpObject)
        case is NSNull:
            return .null
        default:
            // Try to encode as JSON string
            if JSONSerialization.isValidJSONObject(value),
                let jsonData = try? JSONSerialization.data(withJSONObject: value, options: .osaurusCanonical),
                let jsonString = String(data: jsonData, encoding: .utf8)
            {
                return .string(jsonString)
            } else {
                throw NSError(
                    domain: "MCPProviderTool",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unsupported value type: \(type(of: value))"]
                )
            }
        }
    }
}

// MARK: - MCP Content to String Conversion

extension MCPProviderTool {
    /// Stage media off MainActor, forwarding cancellation before publishing a
    /// result. The SDK response already owns its encoded bytes; do not expand
    /// and serialize those bytes again on the provider manager's UI actor.
    static func prepareMCPContent(_ content: [MCP.Tool.Content], toolName: String? = nil) async throws -> String {
        try Task.checkCancellation()
        let conversion = Task.detached(priority: .userInitiated) {
            try convertMCPContent(content, toolName: toolName)
        }
        return try await withTaskCancellationHandler {
            let result = try await conversion.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            conversion.cancel()
        }
    }

    /// Keep typed MCP images out of the text tokenizer and universal TEXT
    /// output cap. References use the same content-addressed attachment store
    /// as file_read and persisted chat, not a second media/cache store.
    static func convertMCPContent(_ content: [MCP.Tool.Content], toolName: String? = nil) throws -> String {
        var results: [[String: Any]] = []
        var hasImages = false

        for item in content {
            try Task.checkCancellation()
            switch item {
            case .text(let text, _, _):
                results.append(["type": "text", "content": text])
            case .image(let data, let mimeType, _, _):
                results.append(try stagedImage(data, mimeType: mimeType))
                hasImages = true
            case .audio(let data, let mimeType, _, _):
                results.append([
                    "type": "audio",
                    "data": data,
                    "mimeType": mimeType,
                ])
            case .resource(let resource, _, _):
                if let mimeType = resource.mimeType, mimeType.hasPrefix("image/"),
                    let blob = resource.blob
                {
                    var image = try stagedImage(blob, mimeType: mimeType)
                    image["uri"] = resource.uri
                    results.append(image)
                    hasImages = true
                    continue
                }
                var result: [String: Any] = [
                    "type": "resource",
                    "uri": resource.uri,
                ]
                if let mimeType = resource.mimeType {
                    result["mimeType"] = mimeType
                }
                if let text = resource.text {
                    result["text"] = text
                }
                results.append(result)
            default:
                break
            }
        }

        try Task.checkCancellation()
        if hasImages {
            return try imageEnvelope(results, toolName: toolName)
        }

        // Wrap even single text at this typed boundary: server-supplied prose
        // resembling our media envelope must never acquire blob privileges.
        if results.count == 1, let content = results[0]["content"] as? String {
            return ToolEnvelope.success(tool: toolName, text: content)
        }

        // Otherwise return JSON array
        if let jsonData = try? JSONSerialization.data(withJSONObject: results, options: .osaurusCanonical),
            let jsonString = String(data: jsonData, encoding: .utf8)
        {
            return ToolEnvelope.success(tool: toolName, text: jsonString)
        }

        return ToolEnvelope.success(tool: toolName, text: "[]")
    }

    /// Apply the existing universal text cap without cutting an image ref in
    /// half. Oversized captions are explicitly truncated; the typed content
    /// array and image order stay intact. This also runs off the UI actor.
    private static func imageEnvelope(_ parts: [[String: Any]], toolName: String?) throws -> String {
        let cap = ToolOutputCaps.universalResult
        var output = ToolEnvelope.success(tool: toolName, result: ["kind": "mcp_content", "content": parts])
        guard output.utf8.count > cap else { return output }
        let warning = "MCP text exceeded the per-call output cap and was truncated; image references were preserved."
        var fraction = min(1, Double(cap) / Double(output.utf8.count))
        for attempt in 0..<12 {
            try Task.checkCancellation()
            let bounded = parts.map { part -> [String: Any] in
                var part = part
                let key: String
                switch part["type"] as? String {
                case "text": key = "content"
                case "resource": key = "text"
                default: return part
                }
                guard let text = part[key] as? String else { return part }
                part[key] = attempt == 11
                    ? "[MCP text omitted: per-call output cap]"
                    : HeadTailTruncation.applyByteExact(text, byteCap: Int(Double(text.utf8.count) * fraction), headFraction: 2.0 / 3.0)
                return part
            }
            output = ToolEnvelope.success(
                tool: toolName, result: ["kind": "mcp_content", "content": bounded], warnings: [warning]
            )
            if output.utf8.count <= cap { return output }
            fraction *= min(0.9, Double(cap) / Double(output.utf8.count))
        }
        throw MCPProviderError.toolExecutionFailed(
            "MCP result metadata exceeds the per-call output cap even without its text. Request fewer items."
        )
    }

    private static func stagedImage(_ encoded: String, mimeType: String) throws -> [String: Any] {
        guard mimeType.hasPrefix("image/"), let data = Data(base64Encoded: encoded), !data.isEmpty,
            let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
            let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0
        else {
            throw MCPProviderError.toolExecutionFailed("MCP tool returned invalid image data (\(mimeType)).")
        }
        try Task.checkCancellation()
        let hash = try AttachmentBlobStore.write(data)
        let actualMime = (CGImageSourceGetType(source) as String?).flatMap { UTType($0)?.preferredMIMEType } ?? mimeType
        return [
            "type": "image", "mimeType": actualMime,
            "image_ref": ["hash": hash, "byte_count": data.count],
            "width": width, "height": height,
        ]
    }
}
