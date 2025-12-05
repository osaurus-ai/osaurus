//
//  MCPProviderTool.swift
//  osaurus
//
//  Tool wrapper for remote MCP provider tools.
//

import Foundation
import MCP

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

    init(
        mcpTool: MCP.Tool,
        providerId: UUID,
        providerName: String,
        prefixWithProvider: Bool = true
    ) {
        self.providerId = providerId
        self.providerName = providerName
        self.mcpToolName = mcpTool.name

        // Optionally prefix tool name with provider name to avoid conflicts
        if prefixWithProvider {
            // Convert provider name to safe identifier (e.g., "My Server" -> "my_server")
            let safeProviderName =
                providerName
                .lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "-", with: "_")
                .filter { $0.isLetter || $0.isNumber || $0 == "_" }
            self.name = "\(safeProviderName)_\(mcpTool.name)"
        } else {
            self.name = mcpTool.name
        }

        // Truncate description to reasonable length
        let desc = mcpTool.description ?? "Tool from \(providerName)"
        self.description = String(desc.prefix(200))

        // Convert MCP input schema to JSONValue
        self.parameters = Self.convertInputSchema(mcpTool.inputSchema)

        // MCP tools require network access
        self.requirements = ["network"]

        // Default to asking for permission since these are remote tools
        self.defaultPermissionPolicy = .ask
    }

    func execute(argumentsJSON: String) async throws -> String {
        // Delegate execution to MCPProviderManager
        return try await MCPProviderManager.shared.executeTool(
            providerId: providerId,
            toolName: mcpToolName,
            argumentsJSON: argumentsJSON
        )
    }

    // MARK: - Schema Conversion

    /// Convert MCP Value schema to Osaurus JSONValue
    private static func convertInputSchema(_ schema: MCP.Value?) -> JSONValue? {
        guard let schema = schema else {
            // Return a basic object schema if none provided
            return .object(["type": .string("object")])
        }
        return convertMCPValue(schema)
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
    /// Convert JSON arguments string to MCP.Value dictionary
    static func convertArgumentsToMCPValues(_ argumentsJSON: String) throws -> [String: MCP.Value] {
        guard let data = argumentsJSON.data(using: .utf8),
            let jsonObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }

        var result: [String: MCP.Value] = [:]
        for (key, value) in jsonObject {
            result[key] = try convertToMCPValue(value)
        }
        return result
    }

    /// Convert Foundation types to MCP.Value
    private static func convertToMCPValue(_ value: Any) throws -> MCP.Value {
        switch value {
        case let stringValue as String:
            return .string(stringValue)
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
            if let jsonData = try? JSONSerialization.data(withJSONObject: value),
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
    /// Convert MCP tool call result content to string response
    static func convertMCPContent(_ content: [MCP.Tool.Content]) -> String {
        var results: [[String: Any]] = []

        for item in content {
            switch item {
            case .text(let text):
                results.append(["type": "text", "content": text])
            case .image(let data, let mimeType, let metadata):
                var result: [String: Any] = [
                    "type": "image",
                    "data": data,
                    "mimeType": mimeType,
                ]
                if let metadata = metadata {
                    result["metadata"] = metadata
                }
                results.append(result)
            case .audio(let data, let mimeType):
                results.append([
                    "type": "audio",
                    "data": data,
                    "mimeType": mimeType,
                ])
            case .resource(let uri, let mimeType, let text):
                var result: [String: Any] = [
                    "type": "resource",
                    "uri": uri,
                    "mimeType": mimeType,
                ]
                if let text = text {
                    result["text"] = text
                }
                results.append(result)
            }
        }

        // If single text result, return just the text
        if results.count == 1, let content = results[0]["content"] as? String {
            return content
        }

        // Otherwise return JSON array
        if let jsonData = try? JSONSerialization.data(withJSONObject: results),
            let jsonString = String(data: jsonData, encoding: .utf8)
        {
            return jsonString
        }

        return "[]"
    }
}
