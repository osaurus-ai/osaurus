//
//  MCPConfigurationImportService.swift
//  OsaurusCore
//
//  Bounded import and preview for common mcpServers JSON configurations.
//

import CryptoKit
import Foundation

enum MCPConfigurationImportReason: String, Sendable, Equatable {
    case invalidUTF8
    case oversized
    case malformedJSON
    case duplicateKey
    case unsupportedRoot
    case tooManyServers
    case invalidServer
    case missingName
    case mixedTransport
    case unsupportedTransport
    case invalidField
    case unsafeValue
    case invalidURL
    case tooManyValues
}

struct MCPConfigurationImportFailure: Error, Sendable, Equatable, LocalizedError {
    let reason: MCPConfigurationImportReason
    let message: String

    var errorDescription: String? { message }
}

struct MCPImportedConfigurationField: Identifiable, Sendable, Equatable {
    let id: String
    let key: String
    let value: String
    var isSecret: Bool

    init(key: String, value: String, isSecret: Bool) {
        self.id = key
        self.key = key
        self.value = value
        self.isSecret = isSecret
    }
}

struct MCPImportedServerConfiguration: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let transport: MCPProviderTransport
    let url: String
    let streamingEnabled: Bool
    let command: String
    let args: [String]
    var environment: [MCPImportedConfigurationField]
    var headers: [MCPImportedConfigurationField]
    let workingDirectory: String?
    let warnings: [String]

    var referencesHostPaths: Bool {
        ([command] + args + [workingDirectory ?? ""]).contains { value in
            value.hasPrefix("/") || value.hasPrefix("~/")
        }
    }

    var reporterSafeSummary: String {
        [
            "mcp-import-preview",
            "name-present=\(!name.isEmpty)",
            "transport=\(transport.rawValue)",
            "streaming=\(streamingEnabled)",
            "argument-count=\(args.count)",
            "environment-keys=\(environment.map(\.key).sorted().joined(separator: ","))",
            "secret-environment-keys=\(environment.filter(\.isSecret).map(\.key).sorted().joined(separator: ","))",
            "header-keys=\(headers.map(\.key).sorted().joined(separator: ","))",
            "secret-header-keys=\(headers.filter(\.isSecret).map(\.key).sorted().joined(separator: ","))",
            "working-directory-present=\(workingDirectory != nil)",
            "host-path-reference=\(referencesHostPaths)",
            "warning-count=\(warnings.count)",
        ].joined(separator: "\n")
    }
}

enum MCPConfigurationImportService {
    static let maximumBytes = 256 * 1024
    static let maximumServers = 32
    static let maximumArguments = 128
    static let maximumFields = 128
    static let maximumStringBytes = 16 * 1024

    static func parse(_ data: Data) throws -> [MCPImportedServerConfiguration] {
        guard data.count <= maximumBytes else {
            throw failure(.oversized, "The MCP configuration is larger than 256 KB.")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw failure(.invalidUTF8, "The MCP configuration is not valid UTF-8.")
        }

        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw failure(.malformedJSON, "The MCP configuration is not valid JSON.")
        }
        if let duplicate = StrictJSONDuplicateKeyScanner.firstDuplicateKey(in: data) {
            throw failure(.duplicateKey, "The MCP configuration contains the duplicate key '\(duplicate)'.")
        }
        try validateAggregateLimits(root)

        guard let object = root as? [String: Any] else {
            throw failure(.unsupportedRoot, "The MCP configuration must be a JSON object.")
        }

        let definitions: [(String?, [String: Any])]
        if let wrapped = object["mcpServers"] {
            guard let servers = wrapped as? [String: Any] else {
                throw failure(.invalidField, "'mcpServers' must be an object keyed by server name.")
            }
            guard !servers.isEmpty else {
                throw failure(.invalidServer, "The MCP configuration does not contain any servers.")
            }
            guard servers.count <= maximumServers else {
                throw failure(.tooManyServers, "The MCP configuration contains more than 32 servers.")
            }
            definitions = try servers.keys.sorted().map { name in
                guard let definition = servers[name] as? [String: Any] else {
                    throw failure(.invalidServer, "The server '\(name)' must be a JSON object.")
                }
                return (name, definition)
            }
        } else if object["command"] != nil || object["url"] != nil {
            definitions = [(object["name"] as? String, object)]
        } else {
            throw failure(
                .unsupportedRoot,
                "Use a top-level 'mcpServers' object or a single server with 'command' or 'url'."
            )
        }

        return try definitions.map { keyName, definition in
            try parseServer(keyName: keyName, definition: definition)
        }
    }

    static func likelySecretKey(_ key: String, isHeader: Bool = false) -> Bool {
        let normalized = key.uppercased().map { character in
            character.isLetter || character.isNumber ? character : "_"
        }
        let normalizedKey = String(normalized)
        if isHeader {
            return normalizedKey == "AUTHORIZATION"
                || normalizedKey == "COOKIE"
                || normalizedKey == "PROXY_AUTHORIZATION"
                || normalizedKey.contains("API_KEY")
                || normalizedKey.contains("TOKEN")
        }
        let markers = ["TOKEN", "SECRET", "PASSWORD", "PASSWD", "CREDENTIAL", "API_KEY", "AUTH"]
        let credentialNames: Set<String> = [
            "AWS_ACCESS_KEY_ID", "AZURE_CLIENT_ID", "DATABASE_URL", "DB_URL",
            "MONGODB_URI", "MYSQL_PWD", "REDIS_URL", "SESSION_ID",
        ]
        return markers.contains { normalizedKey.contains($0) }
            || normalizedKey.hasSuffix("_KEY")
            || normalizedKey.hasSuffix("_PAT")
            || normalizedKey.hasSuffix("_PRIVATE_KEY")
            || credentialNames.contains(normalizedKey)
            || normalizedKey == "GH_PAT"
    }

    private static func parseServer(
        keyName: String?,
        definition: [String: Any]
    ) throws -> MCPImportedServerConfiguration {
        let explicitName = definition["name"] as? String
        let name = (keyName ?? explicitName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw failure(.missingName, "A single-server configuration must include a non-empty 'name'.")
        }
        try validateSafeStructuralString(name, field: "name")

        let command = try optionalString(definition["command"], field: "command")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rawURL = try optionalString(definition["url"], field: "url")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard command.isEmpty || rawURL.isEmpty else {
            throw failure(.mixedTransport, "Server '\(name)' cannot contain both 'command' and 'url'.")
        }

        let declaredType = try optionalString(definition["type"], field: "type")?.lowercased()
        let inferredTransport: MCPProviderTransport
        let streamingEnabled: Bool
        switch declaredType {
        case nil:
            inferredTransport = command.isEmpty ? .http : .stdio
            streamingEnabled = false
        case "stdio":
            guard rawURL.isEmpty else {
                throw failure(.mixedTransport, "Server '\(name)' declares stdio but also contains a URL.")
            }
            inferredTransport = .stdio
            streamingEnabled = false
        case "http", "streamable-http":
            guard command.isEmpty else {
                throw failure(.mixedTransport, "Server '\(name)' declares HTTP but also contains a command.")
            }
            inferredTransport = .http
            streamingEnabled = false
        case "sse":
            guard command.isEmpty else {
                throw failure(.mixedTransport, "Server '\(name)' declares SSE but also contains a command.")
            }
            inferredTransport = .http
            streamingEnabled = true
        default:
            throw failure(.unsupportedTransport, "Server '\(name)' uses an unsupported transport type.")
        }

        let args = try stringArray(definition["args"], field: "args")
        let environment = try fields(
            definition["env"],
            field: "env",
            isHeader: false
        )
        let headers = try fields(
            definition["headers"],
            field: "headers",
            isHeader: true
        )
        let cwd = try coalescedWorkingDirectory(definition)

        var warnings: [String] = []
        switch inferredTransport {
        case .stdio:
            guard !command.isEmpty else {
                throw failure(.invalidServer, "Server '\(name)' is missing its stdio command.")
            }
            try validateSafeStructuralString(command, field: "command")
            guard rawURL.isEmpty, headers.isEmpty else {
                throw failure(.invalidField, "Stdio server '\(name)' cannot contain HTTP headers.")
            }
            let referencesHostPaths = command.hasPrefix("/") || command.hasPrefix("~/")
                || args.contains(where: { $0.hasPrefix("/") || $0.hasPrefix("~/") })
                || (cwd?.hasPrefix("/") == true || cwd?.hasPrefix("~/") == true)
            if referencesHostPaths {
                warnings.append(
                    "This definition references host paths. Keep Sandbox selected unless the server genuinely needs host files."
                )
            }
        case .http:
            guard !rawURL.isEmpty else {
                throw failure(.invalidServer, "Server '\(name)' is missing its HTTP URL.")
            }
            guard args.isEmpty, environment.isEmpty, cwd == nil else {
                throw failure(.invalidField, "HTTP server '\(name)' contains stdio-only fields.")
            }
            try validateHTTPURL(rawURL, name: name)
        }

        return MCPImportedServerConfiguration(
            id: name,
            name: name,
            transport: inferredTransport,
            url: rawURL,
            streamingEnabled: streamingEnabled,
            command: command,
            args: args,
            environment: environment,
            headers: headers,
            workingDirectory: cwd,
            warnings: warnings
        )
    }

    private static func stringArray(_ value: Any?, field: String) throws -> [String] {
        guard let value else { return [] }
        guard let array = value as? [Any] else {
            throw failure(.invalidField, "'\(field)' must be an array of strings.")
        }
        guard array.count <= maximumArguments else {
            throw failure(.tooManyValues, "'\(field)' must contain at most 128 string values.")
        }
        return try array.enumerated().map { index, item in
            guard let string = item as? String else {
                throw failure(.invalidField, "'\(field)[\(index)]' must be a string.")
            }
            try validateSafeStructuralString(string, field: "\(field)[\(index)]")
            return string
        }
    }

    private static func fields(
        _ value: Any?,
        field: String,
        isHeader: Bool
    ) throws -> [MCPImportedConfigurationField] {
        guard let value else { return [] }
        guard let object = value as? [String: Any] else {
            throw failure(.invalidField, "'\(field)' must be an object with string values.")
        }
        guard object.count <= maximumFields else {
            throw failure(.tooManyValues, "'\(field)' must contain at most 128 string values.")
        }
        return try object.keys.sorted().map { key in
            guard let string = object[key] as? String else {
                throw failure(.invalidField, "'\(field).\(key)' must be a string.")
            }
            try validateSafeStructuralString(key, field: "\(field) key")
            try validateStringLength(string, field: "\(field).\(key)")
            if string.unicodeScalars.contains(where: { $0.value == 0 }) {
                throw failure(.unsafeValue, "'\(field).\(key)' contains a NUL character.")
            }
            if isHeader, string.unicodeScalars.contains(where: { $0.value == 10 || $0.value == 13 }) {
                throw failure(.unsafeValue, "Header '\(key)' contains a line break.")
            }
            return MCPImportedConfigurationField(
                key: key,
                value: string,
                isSecret: likelySecretKey(key, isHeader: isHeader)
            )
        }
    }

    private static func coalescedWorkingDirectory(_ definition: [String: Any]) throws -> String? {
        let cwd = try optionalString(definition["cwd"], field: "cwd")
        let workingDirectory = try optionalString(
            definition["workingDirectory"],
            field: "workingDirectory"
        )
        if let cwd, let workingDirectory, cwd != workingDirectory {
            throw failure(.invalidField, "Use either 'cwd' or 'workingDirectory', not both.")
        }
        guard let value = (cwd ?? workingDirectory)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        try validateSafeStructuralString(value, field: "working directory")
        return value
    }

    private static func optionalString(_ value: Any?, field: String) throws -> String? {
        guard let value else { return nil }
        guard let string = value as? String else {
            throw failure(.invalidField, "'\(field)' must be a string.")
        }
        try validateStringLength(string, field: field)
        return string
    }

    private static func validateHTTPURL(_ raw: String, name: String) throws {
        try validateSafeStructuralString(raw, field: "url")
        guard let components = URLComponents(string: raw),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            components.host != nil,
            components.user == nil,
            components.password == nil
        else {
            throw failure(
                .invalidURL,
                "Server '\(name)' must use an HTTP(S) URL without embedded credentials."
            )
        }
    }

    private static func validateAggregateLimits(_ value: Any) throws {
        var stringCount = 0
        func walk(_ item: Any) throws {
            if let string = item as? String {
                stringCount += 1
                guard stringCount <= 4096 else {
                    throw failure(.tooManyValues, "The MCP configuration contains too many values.")
                }
                try validateStringLength(string, field: "JSON string")
            } else if let array = item as? [Any] {
                guard array.count <= 4096 else {
                    throw failure(.tooManyValues, "The MCP configuration contains an oversized array.")
                }
                for child in array { try walk(child) }
            } else if let object = item as? [String: Any] {
                guard object.count <= 4096 else {
                    throw failure(.tooManyValues, "The MCP configuration contains an oversized object.")
                }
                for (key, child) in object {
                    try validateStringLength(key, field: "JSON key")
                    try walk(child)
                }
            }
        }
        try walk(value)
    }

    private static func validateSafeStructuralString(_ value: String, field: String) throws {
        try validateStringLength(value, field: field)
        if value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) {
            throw failure(.unsafeValue, "'\(field)' contains a control character.")
        }
    }

    private static func validateStringLength(_ value: String, field: String) throws {
        guard value.utf8.count <= maximumStringBytes else {
            throw failure(.oversized, "'\(field)' is longer than 16 KB.")
        }
    }

    private static func failure(
        _ reason: MCPConfigurationImportReason,
        _ message: String
    ) -> MCPConfigurationImportFailure {
        MCPConfigurationImportFailure(reason: reason, message: message)
    }
}

enum MCPProviderSetupFingerprint {
    static func make(
        provider: MCPProvider,
        bearerToken: String?,
        secretHeaderValues: [String: String],
        secretEnvironmentValues: [String: String]
    ) -> String {
        var data = (try? JSONEncoder.sorted.encode(provider)) ?? Data()
        append("bearer", bearerToken ?? "", to: &data)
        append(secretHeaderValues, namespace: "header", to: &data)
        append(secretEnvironmentValues, namespace: "environment", to: &data)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func append(
        _ values: [String: String],
        namespace: String,
        to data: inout Data
    ) {
        for key in values.keys.sorted() {
            append("\(namespace).\(key)", values[key] ?? "", to: &data)
        }
    }

    private static func append(_ key: String, _ value: String, to data: inout Data) {
        data.append(Data("\n\(key.utf8.count):\(key)\(value.utf8.count):\(value)".utf8))
    }
}

enum MCPProviderBearerProbeInput {
    private static let clearSentinel = "<clear-requested>"

    static func resolved(
        fieldValue: String,
        clearRequested: Bool,
        storedValue: String?
    ) -> String? {
        let trimmed = fieldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return clearRequested ? nil : storedValue
    }

    static func fingerprint(fieldValue: String, clearRequested: Bool) -> String {
        let trimmed = fieldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return clearRequested ? clearSentinel : ""
    }
}

enum MCPStdioEnvironmentResolver {
    static func providerEnvironment(
        provider: MCPProvider,
        secretEnvOverrides: [String: String]
    ) -> [String: String] {
        var environment = provider.resolvedEnv()
        for (key, value) in secretEnvOverrides where provider.secretEnvKeys.contains(key) {
            environment[key] = value
        }
        return environment
    }
}

struct MCPProviderProbeAttempt: Sendable, Equatable {
    let generation: Int
    let fingerprint: String
}

struct MCPProviderProbeGate: Sendable, Equatable {
    private(set) var generation = 0
    private(set) var successfulFingerprint: String?

    mutating func start(fingerprint: String) -> MCPProviderProbeAttempt {
        generation += 1
        return MCPProviderProbeAttempt(generation: generation, fingerprint: fingerprint)
    }

    mutating func accept(
        _ attempt: MCPProviderProbeAttempt,
        currentFingerprint: String,
        succeeded: Bool
    ) -> Bool {
        guard attempt.generation == generation,
            attempt.fingerprint == currentFingerprint
        else { return false }
        if succeeded {
            successfulFingerprint = currentFingerprint
        } else {
            successfulFingerprint = nil
        }
        return true
    }

    func hasCurrentSuccess(fingerprint: String) -> Bool {
        successfulFingerprint == fingerprint
    }

    mutating func resetSuccess() {
        successfulFingerprint = nil
    }

    mutating func invalidate() {
        generation += 1
        successfulFingerprint = nil
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private enum StrictJSONDuplicateKeyScanner {
    private struct Frame {
        let isObject: Bool
        var expectsKey: Bool
        var keys: Set<String>
    }

    static func firstDuplicateKey(in data: Data) -> String? {
        guard let source = String(data: data, encoding: .utf8) else { return nil }
        let bytes = Array(source.utf8)
        var frames: [Frame] = []
        var index = 0

        while index < bytes.count {
            switch bytes[index] {
            case 0x7B: // {
                frames.append(Frame(isObject: true, expectsKey: true, keys: []))
                index += 1
            case 0x5B: // [
                frames.append(Frame(isObject: false, expectsKey: false, keys: []))
                index += 1
            case 0x7D, 0x5D: // } ]
                if !frames.isEmpty { frames.removeLast() }
                index += 1
            case 0x2C: // ,
                if let last = frames.indices.last, frames[last].isObject {
                    frames[last].expectsKey = true
                }
                index += 1
            case 0x22: // "
                let start = index
                index += 1
                var escaped = false
                while index < bytes.count {
                    let byte = bytes[index]
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    } else if byte == 0x22 {
                        index += 1
                        break
                    }
                    index += 1
                }
                if let last = frames.indices.last,
                    frames[last].isObject,
                    frames[last].expectsKey {
                    guard let key = decodeJSONString(Data(bytes[start ..< index])) else { continue }
                    if !frames[last].keys.insert(key).inserted { return key }
                    frames[last].expectsKey = false
                }
            default:
                index += 1
            }
        }
        return nil
    }

    private static func decodeJSONString(_ data: Data) -> String? {
        try? JSONDecoder().decode(String.self, from: data)
    }
}
