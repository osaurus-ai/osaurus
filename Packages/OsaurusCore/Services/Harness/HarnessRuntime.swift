//
//  HarnessRuntime.swift
//  osaurus
//
//  An external agent harness the user registered with Osaurus — Claude Code,
//  or any Pi-based CLI driven over RPC. A harness owns its own agent loop,
//  tools, and conversation state; Osaurus keeps one long-lived process per
//  chat and forwards only the newest user message.
//

import Foundation

/// The wire protocol a harness speaks. Each kind has exactly one adapter.
public enum HarnessKind: String, Codable, Sendable, CaseIterable, Identifiable {
    /// `claude --print --input-format stream-json --output-format stream-json`.
    case claudeCode
    /// Pi's `--mode rpc` JSONL protocol (Pi itself, or a Pi-based wrapper).
    case piRPC

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode: return L("Claude Code")
        case .piRPC: return L("Pi (RPC)")
        }
    }

    /// Command looked up on PATH when a new runtime of this kind is created.
    public var defaultExecutable: String {
        switch self {
        case .claudeCode: return "claude"
        case .piRPC: return "pi"
        }
    }

    /// Arguments a new runtime of this kind starts with. Claude Code's are
    /// built by its adapter from the agent's settings, so the user list stays
    /// empty; Pi needs RPC mode selected explicitly.
    public var defaultArguments: [String] {
        switch self {
        case .claudeCode: return []
        case .piRPC: return ["--mode", "rpc"]
        }
    }
}

/// A user-registered harness command.
public struct HarnessRuntime: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: HarnessKind
    /// Bare command name (resolved on the login-shell PATH) or a path; a
    /// leading `~` is expanded.
    public var executable: String
    /// Extra arguments. `{chat_id}`, `{agent_id}` and `{cwd}` are substituted
    /// per launch.
    public var arguments: [String]
    /// Extra, non-secret environment for the child. Osaurus's own contract
    /// variables (`OSAURUS_*`) always win over entries here.
    public var environment: [String: String]

    public init(
        id: UUID = UUID(),
        name: String,
        kind: HarnessKind,
        executable: String? = nil,
        arguments: [String]? = nil,
        environment: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.executable = executable ?? kind.defaultExecutable
        self.arguments = arguments ?? kind.defaultArguments
        self.environment = environment
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, executable, arguments, environment
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decode(HarnessKind.self, forKey: .kind)
        executable = try c.decodeIfPresent(String.self, forKey: .executable) ?? kind.defaultExecutable
        arguments = try c.decodeIfPresent([String].self, forKey: .arguments) ?? kind.defaultArguments
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
    }

    /// Display name, never blank.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.displayName : trimmed
    }

    /// Whether the harness can pick its conversation back up after Osaurus
    /// relaunches the process (app restart, folder change, crash).
    ///
    /// Claude Code always can (`--resume <chat id>`). A Pi runtime can only
    /// when its arguments key its session on the chat id, because Pi's RPC
    /// mode has no command to load a session by an id Osaurus chose.
    public var resumesSessions: Bool {
        switch kind {
        case .claudeCode:
            return true
        case .piRPC:
            return arguments.contains { $0.contains(HarnessArgumentPlaceholder.chatId) }
        }
    }

    /// Whether any argument asks for the agent's instructions as a file.
    public var wantsSystemPromptFile: Bool {
        arguments.contains { $0.contains(HarnessArgumentPlaceholder.systemPromptFile) }
    }

    /// Arguments with the launch placeholders substituted.
    public func resolvedArguments(
        chatId: UUID,
        agentId: UUID,
        workingDirectory: URL,
        systemPromptFile: URL? = nil
    ) -> [String] {
        arguments.map {
            $0.replacingOccurrences(of: HarnessArgumentPlaceholder.chatId, with: chatId.uuidString.lowercased())
                .replacingOccurrences(of: HarnessArgumentPlaceholder.agentId, with: agentId.uuidString.lowercased())
                .replacingOccurrences(of: HarnessArgumentPlaceholder.cwd, with: workingDirectory.path)
                .replacingOccurrences(
                    of: HarnessArgumentPlaceholder.systemPromptFile,
                    with: systemPromptFile?.path ?? ""
                )
        }
    }

    /// Well-known id of the runtime seeded on first launch, so migrated agents
    /// and onboarding can point at it without a lookup by name.
    public static let builtInClaudeCodeId = UUID(uuidString: "00000000-0000-0000-0000-00000000C1A0")!

    public static var builtInClaudeCode: HarnessRuntime {
        HarnessRuntime(id: builtInClaudeCodeId, name: "Claude Code", kind: .claudeCode)
    }
}

public enum HarnessArgumentPlaceholder {
    public static let chatId = "{chat_id}"
    public static let agentId = "{agent_id}"
    public static let cwd = "{cwd}"
    /// A private file holding the agent's own instructions, for flags like
    /// Pi's `--append-system-prompt <file>`.
    public static let systemPromptFile = "{system_prompt_file}"

    public static let all = [chatId, agentId, cwd, systemPromptFile]
}

/// Which loop runs an agent's chats.
public enum AgentRuntime: Codable, Sendable, Equatable, Hashable {
    /// Osaurus's own agent loop on the agent's model.
    case builtIn
    /// An external harness owns the loop; Osaurus only relays messages.
    case harness(UUID)

    public var harnessId: UUID? {
        if case .harness(let id) = self { return id }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case kind, id }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        // An unknown kind (written by a newer build) or a malformed id falls
        // back to the built-in loop rather than failing the whole agent decode.
        if kind == "harness", let id = try? c.decode(UUID.self, forKey: .id) {
            self = .harness(id)
        } else {
            self = .builtIn
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtIn:
            try c.encode("builtIn", forKey: .kind)
        case .harness(let id):
            try c.encode("harness", forKey: .kind)
            try c.encode(id, forKey: .id)
        }
    }
}
