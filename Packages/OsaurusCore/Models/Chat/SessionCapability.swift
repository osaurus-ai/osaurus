//
//  SessionCapability.swift
//  osaurus
//
//  Derived "what this chat did" badges, surfaced in the sidebar row so
//  the user can find chats by interaction kind (vision, voice, code,
//  search) instead of having to remember titles.
//

import Foundation

/// Per-session capability flag derived from turns. Set is stored on
/// `ChatSessionData.capabilities` and persisted as a comma-separated
/// TEXT column on `sessions`.
public enum SessionCapability: String, Codable, Hashable, Sendable, CaseIterable {
    case vision
    case voice
    case code
    case search

    /// SF Symbol for the row badge.
    public var iconName: String {
        switch self {
        case .vision: return "eye.fill"
        case .voice: return "waveform"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .search: return "magnifyingglass"
        }
    }

    /// User-facing label used in tooltips and search.
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
    /// Derive the capability set from a session's turns. Tool-name matching
    /// uses substrings on the canonical lowercased name so plugin/MCP
    /// prefixes (e.g. `gmail_api_search`) still classify correctly.
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

    /// Encode/decode for the SQLite TEXT column. Stable, comma-separated,
    /// raw-value form so future additions don't break older rows.
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

    // MARK: - Tool name classification

    /// Sandbox shell, code interpreter, and file-mutating tools.
    private static let codeToolNames: Set<String> = [
        "sandbox_exec",
        "sandbox_execute_code",
        "sandbox_write_file",
        "sandbox_edit_file",
    ]

    /// File-content search plus a fuzzy match for `*search*` in MCP/plugin
    /// tool names (e.g. `gmail_api_search_messages`, `tavily_search`).
    private static func isCodeTool(_ name: String) -> Bool {
        codeToolNames.contains(name)
    }

    private static func isSearchTool(_ name: String) -> Bool {
        if name == "sandbox_search_files" { return true }
        return name.contains("search")
    }
}
