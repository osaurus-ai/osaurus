//
//  ChatImportModels.swift
//  osaurus
//
//  Shared value types for universal chat import: the fetched source
//  bundle, the reader's manifest, and the verified items the approval
//  card lists. Code owns every value that is installed; the reader only
//  names things and points at numbered documents.
//

import Foundation

// MARK: - Source bundle

/// One numbered text the import reader may cite (`d1`, `d2`, …).
struct ChatImportDocument: Sendable, Equatable {
    let id: String
    /// URL the text came from, or "your message".
    let origin: String
    /// Path inside a repository archive, when there is one.
    let path: String?
    let text: String

    var label: String { path.map { "\(origin) — \($0)" } ?? origin }
}

/// A skill folder from a repository archive: `SKILL.md` plus optional
/// `scripts/`, `references/`, and `assets/`.
struct ChatImportSkillPackage: Sendable, Equatable {
    let directory: URL
    let relativePath: String
    let markdown: String
    let origin: String
}

/// A GitHub repository whose root declares a Claude plugin marketplace.
struct ChatImportPluginRepo: Codable, Sendable, Equatable {
    let url: String
    let owner: String
    let name: String
}

/// Why a source could not be imported. Each case has a fixed message so
/// the result never echoes page text.
enum ChatImportRefusal: Sendable, Equatable {
    case insecureURL(String)
    case sshRemote(String)
    case azureDevOps(String)
    case privateOrMissingRepo(String)
    case a2aAgentCard(String)
    case nonStoreTemplate(String)
    case tooLarge(String)
    case fetchFailed(String, reason: String)

    var source: String {
        switch self {
        case .insecureURL(let s), .sshRemote(let s), .azureDevOps(let s), .privateOrMissingRepo(let s),
            .a2aAgentCard(let s), .nonStoreTemplate(let s), .tooLarge(let s):
            return s
        case .fetchFailed(let s, _):
            return s
        }
    }

    var code: String {
        switch self {
        case .insecureURL: return "insecure_url"
        case .sshRemote: return "ssh_remote"
        case .azureDevOps: return "azure_devops"
        case .privateOrMissingRepo: return "private_or_missing_repo"
        case .a2aAgentCard: return "a2a_agent_card"
        case .nonStoreTemplate: return "non_store_template"
        case .tooLarge: return "too_large"
        case .fetchFailed: return "fetch_failed"
        }
    }

    var message: String {
        switch self {
        case .insecureURL:
            return "Only https links can be imported."
        case .sshRemote:
            return "SSH git remotes can't be imported. Share the https GitHub link instead."
        case .azureDevOps:
            return "Azure DevOps repositories can't be imported. Share a public GitHub link or paste the file."
        case .privateOrMissingRepo:
            return "That repository is private or doesn't exist. Only public GitHub repositories can be imported."
        case .a2aAgentCard:
            return "That's an A2A agent card for a remote agent. Osaurus doesn't connect to A2A agents."
        case .nonStoreTemplate:
            return "Osaurus templates install from the template store or a downloaded file, not from links."
        case .tooLarge:
            return "That download is too large to import."
        case .fetchFailed(_, let reason):
            return "Couldn't download it (\(reason))."
        }
    }

    var payload: [String: Any] {
        ["source": source, "code": code, "message": message]
    }
}

/// Everything fetched for one `osaurus_import` call.
struct ChatImportBundle: Sendable {
    var userText: String
    var sources: [String] = []
    var documents: [ChatImportDocument] = []
    var skillPackages: [ChatImportSkillPackage] = []
    var pluginRepos: [ChatImportPluginRepo] = []
    var refusals: [ChatImportRefusal] = []
    /// `osaurus://templates-import` links from the store; they open the
    /// template review sheet instead of installing here.
    var storeTemplateLinks: [URL] = []
    /// Temporary directories (archive extractions) removed after apply.
    var workDirectories: [URL] = []

    /// Every text the verifier may match values against.
    var groundingText: String {
        ([userText] + documents.map(\.text) + skillPackages.map(\.markdown)).joined(separator: "\n")
    }

    func document(_ id: String) -> ChatImportDocument? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return documents.first { $0.id == key }
    }

    func cleanUp() {
        for dir in workDirectories { try? FileManager.default.removeItem(at: dir) }
    }
}

// MARK: - Reader manifest

/// What the import reader reports through `report_import`. Values are
/// names and references only; bodies come from the documents.
struct ChatImportManifest: Sendable, Equatable {
    struct Skill: Sendable, Equatable {
        var name: String
        var description: String
        var doc: String
        var section: String?
    }

    struct Agent: Sendable, Equatable {
        var name: String
        var description: String
        var doc: String
        var section: String?
        var model: String?
        var capabilities: [String]
        var denies: [String]
    }

    struct MCPServer: Sendable, Equatable {
        var name: String
        var url: String?
        var command: String?
        var args: [String]
        var env: [String]
        var headers: [String]
        var auth: String?
    }

    struct Command: Sendable, Equatable {
        var name: String
        var description: String
        var doc: String
        var section: String?
    }

    var summary: String = ""
    var skills: [Skill] = []
    var agents: [Agent] = []
    var mcpServers: [MCPServer] = []
    var commands: [Command] = []
    var manualSteps: [String] = []

    var isEmpty: Bool {
        skills.isEmpty && agents.isEmpty && mcpServers.isEmpty && commands.isEmpty && manualSteps.isEmpty
    }
}

// MARK: - Verified items

enum ChatImportItemKind: String, Codable, Sendable, Equatable, CaseIterable {
    case skill
    case agent
    case mcpServer = "mcp_server"
    case command
    case plugin
    case manualStep = "manual_step"

    var sectionTitle: String {
        switch self {
        case .skill: return L("Skills")
        case .agent: return L("Agents")
        case .mcpServer: return L("MCP Servers")
        case .command: return L("Commands")
        case .plugin: return L("Plugins")
        case .manualStep: return L("Manual Steps")
        }
    }
}

/// How an item relates to what is already installed.
enum ChatImportItemState: String, Codable, Sendable, Equatable {
    case new
    case alreadyInstalled = "already_installed"
    case updateAvailable = "update_available"
    case nameClash = "name_clash"
}

enum ChatImportClashChoice: String, Codable, Sendable, Equatable {
    case replace
    case keepBoth = "keep_both"
}

/// Instructions installed as a skill or as an agent's system prompt.
struct ChatImportInstructionsSpec: Codable, Sendable, Equatable {
    var name: String
    var description: String
    var instructions: String
    /// Folder with `scripts/`, `references/`, `assets/` to copy alongside.
    var packageDirectory: URL?
    var model: String?
    var capabilities: [String] = []
    var deniesShell = false
    var deniesNetwork = false
}

struct ChatImportMCPSpec: Codable, Sendable, Equatable {
    var entry: MCPServerEntry
    /// Env var / header names the user still has to fill in Settings.
    var pendingSecrets: [String] = []
    var runsDocker = false
}

enum ChatImportItemPayload: Codable, Sendable, Equatable {
    /// Skill or agent: the same instructions, installed as either.
    case instructions(ChatImportInstructionsSpec)
    case mcpServer(ChatImportMCPSpec)
    case command(CommandEntry)
    case plugin(ChatImportPluginRepo)
    case manualStep(String)
}

/// One row on the import card.
struct ChatImportItem: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var kind: ChatImportItemKind
    var name: String
    var detail: String
    var origin: String
    var payload: ChatImportItemPayload
    var included = true
    var state: ChatImportItemState = .new
    var clashChoice: ChatImportClashChoice?
    var risks: [String] = []
    var warnings: [String] = []
    var needsSetup: [String] = []
    /// Set when the item can't be installed here; the row can't be checked.
    var blockedReason: String?
    /// Source hash recorded in provenance; re-imports compare against it.
    var contentHash: String = ""

    /// Skill and agent rows let the user pick which one they become.
    var allowsKindChoice: Bool {
        if case .instructions = payload { return true }
        return false
    }

    var isActionable: Bool { kind != .manualStep && blockedReason == nil }
}

/// The user's per-row answer on the card.
struct ChatImportItemChoice: Sendable, Equatable {
    var included: Bool
    var kind: ChatImportItemKind
    var clash: ChatImportClashChoice?
}

/// Where the import runs, which decides the default for skill-or-agent
/// rows and what "install" means.
enum ChatImportSurface: String, Sendable, Equatable {
    case mainChat = "main_chat"
    case agentCreation = "agent_creation"
}

/// The card's content: what was found and what will be installed.
struct ChatImportReview: Sendable, Equatable {
    var items: [ChatImportItem]
    var refusals: [ChatImportRefusal]
    var notes: [String]
    var surface: ChatImportSurface
    var targetAgentName: String?

    var defaultChoices: [String: ChatImportItemChoice] {
        Dictionary(
            uniqueKeysWithValues: items.map {
                ($0.id, ChatImportItemChoice(included: $0.included && $0.isActionable, kind: $0.kind, clash: $0.clashChoice))
            })
    }

    /// The review as a plan, for Attention and the paired phone.
    var plan: ConfigPlan {
        var actions: [ConfigPlanAction] = []
        for item in items where item.isActionable {
            let kind: ConfigPlanAction.Kind = item.state == .updateAvailable ? .update : .create
            var changes: [String] = []
            if !item.detail.isEmpty { changes.append(String(item.detail.prefix(160))) }
            if !item.needsSetup.isEmpty { changes.append("needs setup: " + item.needsSetup.joined(separator: ", ")) }
            if !item.included { changes.append("unchecked") }
            actions.append(
                ConfigPlanAction(
                    section: item.kind.sectionTitle, target: item.name, kind: kind, changes: changes,
                    risks: item.risks))
        }
        var notes = notes
        for item in items where item.kind == .manualStep { notes.append("Manual step: \(item.name)") }
        return ConfigPlan(actions: actions, notes: notes)
    }
}

// MARK: - Results

/// Outcome of one row after apply.
struct ChatImportItemResult: Sendable, Equatable {
    enum Status: String, Sendable {
        case installed
        case updated
        case skipped
        case needsSetup = "needs_setup"
        case failed
        case rolledBack = "rolled_back"
    }

    var kind: ChatImportItemKind
    var name: String
    var status: Status
    var message: String?

    var payload: [String: Any] {
        var row: [String: Any] = ["kind": kind.rawValue, "name": name, "status": status.rawValue]
        if let message { row["message"] = message }
        return row
    }
}

// MARK: - Hashing

enum ChatImportHash {
    /// Stable content hash (FNV-1a 64) for provenance comparisons. Not a
    /// security boundary; it only answers "did the source change".
    static func of(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
