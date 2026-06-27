//
//  MCPProviderCallHistoryStore.swift
//  osaurus
//
//  Bounded, redacted MCP provider call history for the operations hub.
//

import Foundation

extension Foundation.Notification.Name {
    static let mcpProviderCallHistoryChanged = Foundation.Notification.Name(
        "MCPProviderCallHistoryChanged"
    )
}

public struct MCPProviderCallRecord: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public let providerId: UUID
    public let providerName: String
    public let toolName: String
    public let startedAt: Date
    public let finishedAt: Date
    public let succeeded: Bool
    public let argumentSummary: String
    public let resultSummary: String?
    public let errorMessage: String?

    public init(
        id: UUID = UUID(),
        providerId: UUID,
        providerName: String,
        toolName: String,
        startedAt: Date,
        finishedAt: Date,
        succeeded: Bool,
        argumentSummary: String,
        resultSummary: String? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.providerId = providerId
        self.providerName = providerName
        self.toolName = toolName
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.succeeded = succeeded
        self.argumentSummary = MCPProviderProbeRedactor.safeDiagnosticFragment(argumentSummary, maxLength: 180)
        self.resultSummary = resultSummary.map {
            MCPProviderProbeRedactor.safeDiagnosticFragment($0, maxLength: 180)
        }
        self.errorMessage = errorMessage.map {
            MCPProviderProbeRedactor.safeDiagnosticFragment($0, maxLength: 280)
        }
    }

    public var durationMilliseconds: Int {
        max(0, Int(finishedAt.timeIntervalSince(startedAt) * 1_000))
    }

    public var statusText: String {
        succeeded ? L("Succeeded") : L("Failed")
    }

    public var pasteboardText: String {
        var lines = [
            "MCP provider call",
            "Provider: \(providerName)",
            "Tool: \(toolName)",
            "Status: \(succeeded ? "succeeded" : "failed")",
            "Duration: \(durationMilliseconds)ms",
            "Arguments: \(argumentSummary)",
        ]
        if let resultSummary, !resultSummary.isEmpty {
            lines.append("Result: \(resultSummary)")
        }
        if let errorMessage, !errorMessage.isEmpty {
            lines.append("Error: \(errorMessage)")
        }
        return lines.joined(separator: "\n")
    }

    public static func summarizeArguments(_ argumentsJSON: String) -> String {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return L("No arguments") }
        guard let data = trimmed.data(using: .utf8) else {
            return L("Arguments present (not UTF-8)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            return L("Arguments present (invalid JSON redacted)")
        }
        if let dictionary = object as? [String: Any] {
            if dictionary.isEmpty { return L("Empty object") }
            let keys = dictionary.keys.sorted()
            return L("Object keys: \(keys.joined(separator: ", "))")
        }
        if let array = object as? [Any] {
            return L("Array with \(array.count) item(s)")
        }
        return L("JSON \(type(of: object)) argument")
    }

    public static func summarizeResult(_ result: String) -> String {
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return L("Empty result")
        }
        return L("\(result.count) character(s)")
    }
}

public enum MCPProviderCallHistoryStore {
    nonisolated(unsafe) public static var overrideURL: URL?
    public static let maxRecordsPerProvider = 50
    private static let lock = NSLock()

    private struct Envelope: Codable, Sendable, Equatable {
        var records: [MCPProviderCallRecord]
    }

    public static func load() -> [UUID: [MCPProviderCallRecord]] {
        withLock {
            loadUnlocked()
        }
    }

    public static func recentCalls(providerId: UUID, limit: Int = maxRecordsPerProvider) -> [MCPProviderCallRecord] {
        Array((load()[providerId] ?? []).prefix(limit))
    }

    public static func record(_ record: MCPProviderCallRecord) {
        withLock {
            var grouped = loadUnlocked()
            var records = grouped[record.providerId] ?? []
            records.insert(record, at: 0)
            grouped[record.providerId] = Array(sortRecentFirst(records).prefix(maxRecordsPerProvider))
            saveUnlocked(grouped)
        }
        notify(providerId: record.providerId)
    }

    public static func clear(providerId: UUID) {
        withLock {
            var grouped = loadUnlocked()
            grouped.removeValue(forKey: providerId)
            saveUnlocked(grouped)
        }
        notify(providerId: providerId)
    }

    public static func clearAll() {
        withLock {
            saveUnlocked([:])
        }
        notify(providerId: nil)
    }

    private static func loadUnlocked() -> [UUID: [MCPProviderCallRecord]] {
        let url = fileURL()
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return [:] }
        return Dictionary(grouping: envelope.records, by: \.providerId).mapValues(sortRecentFirst)
    }

    private static func saveUnlocked(_ grouped: [UUID: [MCPProviderCallRecord]]) {
        let url = fileURL()
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        let records = grouped.values
            .flatMap { $0 }
            .sorted {
                if $0.startedAt == $1.startedAt {
                    return $0.id.uuidString < $1.id.uuidString
                }
                return $0.startedAt > $1.startedAt
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(Envelope(records: records)).write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save MCP call history: \(error)")
        }
    }

    private static func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private static func fileURL() -> URL {
        if let overrideURL { return overrideURL }
        return OsaurusPaths.providers().appendingPathComponent("mcp-call-history.json")
    }

    private static func sortRecentFirst(_ records: [MCPProviderCallRecord]) -> [MCPProviderCallRecord] {
        records.sorted {
            if $0.startedAt == $1.startedAt {
                return $0.id.uuidString < $1.id.uuidString
            }
            return $0.startedAt > $1.startedAt
        }
    }

    private static func notify(providerId: UUID?) {
        NotificationCenter.default.post(
            name: Foundation.Notification.Name.mcpProviderCallHistoryChanged,
            object: providerId
        )
    }
}
