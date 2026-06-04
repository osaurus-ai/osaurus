//
//  SessionCapability.swift
//  osaurus
//
//  Per-chat capability badges (vision / voice / code / search).
//

import Foundation

/// Per-session capability tag derived from turns and persisted as a
/// comma-separated TEXT column on `sessions`.
public enum SessionCapability: String, Codable, Hashable, Sendable, CaseIterable {
    case vision
    case voice
    case code
    case search

    public var iconName: String {
        switch self {
        case .vision: return "eye.fill"
        case .voice: return "waveform"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .search: return "magnifyingglass"
        }
    }

    public var label: String {
        switch self {
        case .vision: return "Vision"
        case .voice: return "Voice"
        case .code: return "Code"
        case .search: return "Search"
        }
    }
}

extension SessionCapability {
    /// Match plugin/MCP-prefixed names by substring on the lowercased name.
    public static func derive(from turns: [ChatTurnData]) -> Set<SessionCapability> {
        var caps: Set<SessionCapability> = []

        for turn in turns {
            for attachment in turn.attachments {
                if attachment.isImage { caps.insert(.vision) }
                if attachment.isAudio { caps.insert(.voice) }
            }
            guard let toolCalls = turn.toolCalls else { continue }
            for call in toolCalls {
                let name = call.function.name.lowercased()
                if isCodeTool(name) { caps.insert(.code) }
                if isSearchTool(name) { caps.insert(.search) }
            }
            if caps.count == SessionCapability.allCases.count { return caps }
        }
        return caps
    }

    /// Stable comma-separated raw values for the SQLite column.
    public static func encode(_ caps: Set<SessionCapability>) -> String {
        SessionCapability.allCases
            .filter { caps.contains($0) }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    public static func decode(_ string: String) -> Set<SessionCapability> {
        guard !string.isEmpty else { return [] }
        return Set(
            string
                .split(separator: ",")
                .compactMap { SessionCapability(rawValue: String($0)) }
        )
    }

    private static let codeToolNames: Set<String> = [
        "sandbox_exec",
        "sandbox_write_file",
    ]

    private static func isCodeTool(_ name: String) -> Bool {
        codeToolNames.contains(name)
    }

    private static func isSearchTool(_ name: String) -> Bool {
        if name == "sandbox_search_files" { return true }
        return name.contains("search")
    }
}
