//
//  SupportDiagnosticsBundle.swift
//  osaurus
//
//  Privacy-preserving support bundle for diagnosing request/tool state without
//  exporting prompts, responses, wire bodies, free-form error text, or raw
//  stable identifiers.
//

import CryptoKit
import Foundation

struct SupportDiagnosticsBundle: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let generatedAt: Date
    let app: AppSnapshot
    let context: ContextSnapshot
    let tools: ToolInventorySnapshot
    let recentRequests: [RequestSnapshot]
    let privacy: PrivacySnapshot

    struct AppSnapshot: Codable, Equatable, Sendable {
        let name: String?
        let version: String?
        let build: String?
        let osVersion: String

        static func current(bundle: Bundle = .main) -> AppSnapshot {
            let info = bundle.infoDictionary ?? [:]
            return AppSnapshot(
                name: info["CFBundleName"] as? String,
                version: info["CFBundleShortVersionString"] as? String,
                build: info["CFBundleVersion"] as? String,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString
            )
        }
    }

    struct ContextSnapshot: Codable, Equatable, Sendable {
        let sessionIdFingerprint: String?
        let agentIdFingerprint: String?
        let agentAddressFingerprint: String?
        let agentName: String?
        let modelId: String?
        let providerIdFingerprint: String?
        let runtime: String?
        let toolMode: String?
    }

    struct ToolInventorySnapshot: Codable, Equatable, Sendable {
        let registered: [ToolRecord]
        let enabledNames: [String]
        let dynamicNames: [String]
        let loadedNames: [String]
        let initialAlwaysLoadedNames: [String]
        let sessionFingerprint: String?
    }

    struct ToolRecord: Codable, Equatable, Sendable {
        let name: String
        let enabled: Bool
        let groupName: String?
    }

    struct RequestSnapshot: Codable, Equatable, Sendable {
        let idFingerprint: String
        let timestamp: Date
        let source: String
        let turnIdFingerprint: String?
        let requestIdFingerprint: String?
        let method: String
        let path: String
        let statusCode: Int
        let durationMs: Double
        let userAgent: String?
        let pluginId: String?
        let model: String?
        let inputTokens: Int?
        let outputTokens: Int?
        let tokensPerSecond: Double?
        let temperature: Float?
        let maxTokens: Int?
        let finishReason: String?
        let errorMessageCaptured: Bool
        let bodyPresence: BodyPresence
        let toolCalls: [ToolCallSnapshot]
        let connection: ConnectionSnapshot?
    }

    struct BodyPresence: Codable, Equatable, Sendable {
        let localRequestCaptured: Bool
        let localResponseCaptured: Bool
        let wireRequestCaptured: Bool
        let wireResponseCaptured: Bool
    }

    struct ToolCallSnapshot: Codable, Equatable, Sendable {
        let idFingerprint: String
        let name: String
        let argumentKeyCount: Int
        let argumentByteCount: Int
        let durationMs: Double?
        let isError: Bool
        let resultCaptured: Bool
    }

    struct ConnectionSnapshot: Codable, Equatable, Sendable {
        let providerIdFingerprint: String?
        let remoteEndpoint: String?
        let transport: String?
        let mode: String?
        let accessKeyIdFingerprint: String?
        let audienceFingerprint: String?
    }

    struct PrivacySnapshot: Codable, Equatable, Sendable {
        let redactedValue: String
        let omittedFields: [String]
        let notes: [String]

        static let standard = PrivacySnapshot(
            redactedValue: SupportDiagnosticsBundleBuilder.redactedValue,
            omittedFields: [
                "requestBody",
                "responseBody",
                "wireRequestBody",
                "wireResponseBody",
                "toolCall.arguments",
                "toolCall.argumentKeys",
                "toolCall.result",
                "sessionId",
                "turnId",
                "logId",
                "toolCall.id",
                "agentId",
                "agentAddress",
                "providerId",
                "connection.providerId",
                "accessKeyId",
                "audience",
                "plugin.path",
                "pluginLog.message",
                "errorMessage",
            ],
            notes: [
                "Request, response, and wire bodies are omitted.",
                "Tool call argument names, values, and results are omitted.",
                "Session, request, turn, log, agent, provider, access-key, and audience identifiers are SHA-256 fingerprints.",
                "Plugin paths, console messages, and provider error text are represented only as captured/omitted state.",
                "Endpoint metadata omits query strings and redacts identity-shaped path segments.",
                "Short identifier metadata strings are scanned for common bearer/token secrets.",
            ]
        )
    }
}

struct SupportDiagnosticsToolInput: Equatable, Sendable {
    let name: String
    let enabled: Bool
    let groupName: String?

    init(name: String, enabled: Bool, groupName: String? = nil) {
        self.name = name
        self.enabled = enabled
        self.groupName = groupName
    }
}

enum SupportDiagnosticsBundleBuilder {
    static let redactedValue = "[REDACTED]"

    @MainActor
    static func buildCurrent(
        generatedAt: Date = Date(),
        sessionId: String? = nil,
        agentId: UUID? = nil,
        agentAddress: String? = nil,
        agentName: String? = nil,
        modelId: String? = nil,
        providerId: String? = nil,
        runtime: String? = nil,
        toolMode: String? = nil,
        recentLogLimit: Int = 50
    ) async -> SupportDiagnosticsBundle {
        let registry = ToolRegistry.shared
        let registered = registry.listTools().map { entry in
            SupportDiagnosticsToolInput(
                name: entry.name,
                enabled: entry.enabled,
                groupName: registry.groupName(for: entry.name)
            )
        }
        let dynamicNames = registry.listDynamicTools().map(\.name)
        let sessionState: SessionToolState?
        if let sessionId {
            sessionState = await SessionToolStateStore.shared.get(sessionId)
        } else {
            sessionState = nil
        }

        return make(
            generatedAt: generatedAt,
            app: .current(),
            sessionId: sessionId,
            agentId: agentId,
            agentAddress: agentAddress,
            agentName: agentName,
            modelId: modelId,
            providerId: providerId,
            runtime: runtime,
            toolMode: toolMode,
            registeredTools: registered,
            dynamicToolNames: dynamicNames,
            sessionState: sessionState,
            logs: InsightsService.shared.logs,
            recentLogLimit: recentLogLimit
        )
    }

    static func make(
        generatedAt: Date = Date(),
        app: SupportDiagnosticsBundle.AppSnapshot = .current(),
        sessionId: String? = nil,
        agentId: UUID? = nil,
        agentAddress: String? = nil,
        agentName: String? = nil,
        modelId: String? = nil,
        providerId: String? = nil,
        runtime: String? = nil,
        toolMode: String? = nil,
        registeredTools: [SupportDiagnosticsToolInput] = [],
        dynamicToolNames: [String] = [],
        sessionState: SessionToolState? = nil,
        logs: [RequestLog] = [],
        recentLogLimit: Int = 50
    ) -> SupportDiagnosticsBundle {
        // Pure constructor for tests and already-snapshotted inputs. Live app
        // export flows should call buildCurrent so actor-owned state is read
        // from the correct isolation domain before arriving here.
        let context = SupportDiagnosticsBundle.ContextSnapshot(
            sessionIdFingerprint: fingerprint(sessionId),
            agentIdFingerprint: fingerprint(agentId),
            agentAddressFingerprint: fingerprint(agentAddress),
            agentName: redactedMetadata(agentName),
            modelId: redactedMetadata(modelId),
            providerIdFingerprint: fingerprint(providerId),
            runtime: redactedMetadata(runtime),
            toolMode: redactedMetadata(toolMode)
        )

        let registeredRecords = registeredTools
            .map {
                SupportDiagnosticsBundle.ToolRecord(
                    name: $0.name,
                    enabled: $0.enabled,
                    groupName: redactedMetadata($0.groupName)
                )
            }
            .sorted { compareIdentifiers($0.name, $1.name) }
        let tools = SupportDiagnosticsBundle.ToolInventorySnapshot(
            registered: registeredRecords,
            enabledNames: sortedUnique(registeredTools.filter(\.enabled).map(\.name)),
            dynamicNames: sortedUnique(dynamicToolNames),
            loadedNames: sortedUnique(Array(sessionState?.loadedToolNames ?? [])),
            initialAlwaysLoadedNames: sortedUnique(Array(sessionState?.initialAlwaysLoadedNames ?? [])),
            sessionFingerprint: redactedMetadata(sessionState?.sessionFingerprint)
        )

        let limit = max(0, recentLogLimit)
        let recentRequests = logs
            .sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.timestamp > rhs.timestamp
            }
            .prefix(limit)
            .map(snapshot)

        return SupportDiagnosticsBundle(
            schemaVersion: SupportDiagnosticsBundle.schemaVersion,
            generatedAt: generatedAt,
            app: app,
            context: context,
            tools: tools,
            recentRequests: recentRequests,
            privacy: .standard
        )
    }

    private static func snapshot(_ log: RequestLog) -> SupportDiagnosticsBundle.RequestSnapshot {
        SupportDiagnosticsBundle.RequestSnapshot(
            idFingerprint: fingerprint(log.id.uuidString) ?? "",
            timestamp: log.timestamp,
            source: log.source.rawValue,
            turnIdFingerprint: fingerprint(log.turnId),
            requestIdFingerprint: fingerprint(log.requestId),
            method: redactedMetadata(log.method) ?? "",
            path: diagnosticPath(for: log),
            statusCode: log.statusCode,
            durationMs: log.durationMs,
            userAgent: redactedMetadata(log.userAgent),
            pluginId: redactedMetadata(log.pluginId),
            model: redactedMetadata(log.model),
            inputTokens: log.inputTokens,
            outputTokens: log.outputTokens,
            tokensPerSecond: log.tokensPerSecond,
            temperature: log.temperature,
            maxTokens: log.maxTokens,
            finishReason: log.finishReason?.rawValue,
            errorMessageCaptured: hasContent(log.errorMessage),
            bodyPresence: SupportDiagnosticsBundle.BodyPresence(
                localRequestCaptured: log.requestBody != nil,
                localResponseCaptured: log.responseBody != nil,
                wireRequestCaptured: log.wireRequestBody != nil,
                wireResponseCaptured: log.wireResponseBody != nil
            ),
            toolCalls: (log.toolCalls ?? []).map(snapshot),
            connection: log.connection.map(snapshot)
        )
    }

    private static func snapshot(_ call: ToolCallLog) -> SupportDiagnosticsBundle.ToolCallSnapshot {
        SupportDiagnosticsBundle.ToolCallSnapshot(
            idFingerprint: fingerprint(call.id.uuidString) ?? "",
            name: redactedMetadata(call.name) ?? "",
            argumentKeyCount: argumentKeyCount(from: call.arguments),
            argumentByteCount: call.arguments.utf8.count,
            durationMs: call.durationMs,
            isError: call.isError,
            resultCaptured: call.result != nil
        )
    }

    private static func snapshot(_ connection: RequestConnectionInfo)
        -> SupportDiagnosticsBundle.ConnectionSnapshot
    {
        SupportDiagnosticsBundle.ConnectionSnapshot(
            providerIdFingerprint: fingerprint(connection.providerId),
            remoteEndpoint: sanitizedEndpoint(connection.remoteEndpoint),
            transport: connection.transport?.rawValue,
            mode: connection.mode?.rawValue,
            accessKeyIdFingerprint: fingerprint(connection.accessKeyId),
            audienceFingerprint: fingerprint(connection.audience)
        )
    }

    private static func argumentKeyCount(from arguments: String) -> Int {
        guard let data = arguments.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return 0
        }
        return object.keys.count
    }

    private static func diagnosticPath(for log: RequestLog) -> String {
        if log.source == .plugin {
            return "[plugin path omitted]"
        }
        return sanitizedEndpoint(log.path) ?? ""
    }

    private static func sanitizedEndpoint(_ value: String?) -> String? {
        guard let value = redactedMetadata(value) else { return nil }
        let withoutQuery = value.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? value
        let withoutFragment = withoutQuery.split(
            separator: "#",
            maxSplits: 1,
            omittingEmptySubsequences: false
        ).first.map(String.init) ?? withoutQuery
        return redactIdentitySegments(in: withoutFragment)
    }

    private static func redactIdentitySegments(in value: String) -> String {
        var output = value
        output = replacing(
            pattern: #"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#,
            in: output,
            template: "[uuid]"
        )
        output = replacing(
            pattern: #"\b0x[0-9A-Fa-f]{40}\b"#,
            in: output,
            template: "0x[REDACTED]"
        )
        output = replacing(
            pattern: #"/[A-Za-z0-9._~%-]{32,}(?=/|$)"#,
            in: output,
            template: "/[id]"
        )
        return output
    }

    private static func fingerprint(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        let digest = SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:" + String(digest.prefix(16))
    }

    private static func fingerprint(_ value: UUID?) -> String? {
        fingerprint(value?.uuidString)
    }

    private static func hasContent(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func redactedMetadata(_ value: String?, maxLength: Int = 512) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        let clipped: String
        if value.count > maxLength {
            clipped = String(value.prefix(maxLength)) + "...[truncated]"
        } else {
            clipped = value
        }
        return redactSecretLikeSubstrings(clipped)
    }

    private static func redactSecretLikeSubstrings(_ value: String) -> String {
        var output = value
        output = replacing(
            pattern: #"(?i)(bearer\s+)[^\s,;]+"#,
            in: output,
            template: "$1\(redactedValue)"
        )
        output = replacing(
            pattern: #"(?i)(authorization\s*[:=]\s*)(?:basic|bearer|token)?\s*[^\s,;]+"#,
            in: output,
            template: "$1\(redactedValue)"
        )
        output = replacing(
            pattern: #"(?i)((?:^|[^\w])"?(?:api[_-]?key|access[_-]?token|refresh[_-]?token|token|secret|password|code)"?\s*[=:]\s*)"?[^\s"&;,}]+"?"#,
            in: output,
            template: "$1\(redactedValue)"
        )
        output = replacing(
            pattern: #"(?i)([a-z][a-z0-9+.-]*://)[^/@:\s]+(?::[^/@\s]*)?@"#,
            in: output,
            template: "$1\(redactedValue)@"
        )
        output = replacing(
            pattern: #"\bsk-[A-Za-z0-9._-]{8,}\b"#,
            in: output,
            template: redactedValue
        )
        return output
    }

    private static func replacing(pattern: String, in value: String, template: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: template
        )
    }

    private static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted(by: compareIdentifiers)
    }

    private static func compareIdentifiers(_ lhs: String, _ rhs: String) -> Bool {
        let order = lhs.caseInsensitiveCompare(rhs)
        if order == .orderedSame {
            return lhs < rhs
        }
        return order == .orderedAscending
    }
}
