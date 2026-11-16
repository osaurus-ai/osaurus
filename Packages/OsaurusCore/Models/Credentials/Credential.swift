//
//  Credential.swift
//  osaurus
//
//  Model for the unified credentials store: one env-var-style key, saved
//  either for all agents (global) or for one agent. The agent's value wins.
//

import Foundation

/// Who a credential applies to.
public enum CredentialScope: Hashable, Sendable {
    /// Shared by every agent unless that agent has its own value.
    case global
    /// Only this agent. Overrides a global value with the same key.
    case agent(UUID)

    public var agentId: UUID? {
        if case .agent(let id) = self { return id }
        return nil
    }

    /// Closed analytics token: `shared` or `agent`, never the agent id.
    var telemetryToken: String {
        agentId == nil ? "shared" : "agent"
    }

    /// Keychain account prefix. Agent ids are lowercased so the account is
    /// stable regardless of how the UUID was formatted by the caller.
    var accountPrefix: String {
        switch self {
        case .global: return "global/"
        case .agent(let id): return "agent/\(id.uuidString.lowercased())/"
        }
    }

    func account(for key: String) -> String { accountPrefix + key }

    /// Inverse of `account(for:)`: `global/KEY` or `agent/<uuid>/KEY`.
    static func parse(account: String) -> (CredentialScope, String)? {
        let parts = account.split(separator: "/", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "global" where parts.count == 2 && CredentialKeys.isValid(parts[1]):
            return (.global, parts[1])
        case "agent" where parts.count == 3 && CredentialKeys.isValid(parts[2]):
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            return (.agent(id), parts[2])
        default:
            return nil
        }
    }
}

/// A problem reading the store's files, shown on the Keys page.
public enum CredentialLoadIssue: Equatable, Sendable {
    /// The list of keys was unreadable; it was rebuilt from the Keychain.
    case indexRebuilt(backup: URL, recovered: Int)
    /// The list of keys was unreadable and the Keychain is locked; nothing
    /// is written until it can be rebuilt.
    case indexRecoveryPending(backup: URL)
    /// Which key each integration uses was unreadable and was reset.
    case bindingsReset(backup: URL)

    public var backup: URL? {
        switch self {
        case .indexRebuilt(let backup, _), .indexRecoveryPending(let backup), .bindingsReset(let backup):
            return backup
        }
    }
}

extension CredentialScope: Codable {
    private enum CodingKeys: String, CodingKey { case type, agentId }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if type == "agent", let id = try container.decodeIfPresent(UUID.self, forKey: .agentId) {
            self = .agent(id)
        } else {
            self = .global
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try container.encode("global", forKey: .type)
        case .agent(let id):
            try container.encode("agent", forKey: .type)
            try container.encode(id, forKey: .agentId)
        }
    }
}

/// Whether the value is hidden. Secrets live in the Keychain and are
/// scrubbed from tool output; variables are plain settings stored in the
/// index and shown in clear.
public enum CredentialKind: String, Codable, Sendable, CaseIterable {
    case secret
    case variable
}

/// What created the credential. Drives the default for sandbox exposure
/// and the "Used by" hint for orphaned values.
public enum CredentialOrigin: String, Codable, Sendable {
    case user
    case mcp
    case plugin
    case channel
    case workflow
    case sandboxPrompt
    case config

    /// User-created and model-requested values are meant for the agent's
    /// own code; values created by an integration's setup only reach that
    /// integration unless the user opts in.
    var exposesToSandboxByDefault: Bool {
        switch self {
        case .user, .sandboxPrompt: return true
        case .mcp, .plugin, .channel, .workflow, .config: return false
        }
    }
}

/// Non-secret metadata for one credential. The secret value itself is
/// never part of this record; `variableValue` is only set for variables.
public struct CredentialRecord: Codable, Equatable, Sendable, Identifiable {
    public var key: String
    public var scope: CredentialScope
    public var kind: CredentialKind
    public var description: String
    public var exposeToSandbox: Bool
    public var origin: CredentialOrigin
    public var createdAt: Date
    public var updatedAt: Date
    var variableValue: String?

    public var id: String { scope.account(for: key) }

    public init(
        key: String,
        scope: CredentialScope,
        kind: CredentialKind = .secret,
        description: String = "",
        exposeToSandbox: Bool,
        origin: CredentialOrigin,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        variableValue: String? = nil
    ) {
        self.key = key
        self.scope = scope
        self.kind = kind
        self.description = description
        self.exposeToSandbox = exposeToSandbox
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.variableValue = variableValue
    }
}

/// Where an effective value came from, for "Same as all agents" vs
/// "Different value for this agent" in the UI.
public enum CredentialValueSource: Equatable, Sendable {
    case agent
    case global
    case legacy
}

/// Result of a credential write.
public enum CredentialWriteOutcome: Equatable, Sendable {
    case success
    case emptyValue
    case invalidKey
    case keychainFailure(String)
    /// Another key already has this name.
    case nameInUse
    /// The Keychain accepted the change but `credentials/index.json`
    /// couldn't be written, so it may not survive a relaunch.
    case indexWriteFailed
    /// Longer than `CredentialStore.maxValueBytes`.
    case valueTooLong

    public var isSuccess: Bool { self == .success }

    public var failureDescription: String? {
        switch self {
        case .success: return nil
        case .emptyValue: return L("Enter a value.")
        case .invalidKey:
            return L("Names can use letters, numbers and underscores, and can't start with a number.")
        case .keychainFailure(let detail): return L("The Keychain didn't accept the change: \(detail)")
        case .nameInUse: return L("This name is already used. Pick another or edit the existing key.")
        case .indexWriteFailed:
            return L("The change works now but couldn't be saved to disk. Check that the ~/.osaurus folder is writable.")
        case .valueTooLong: return L("Values can be up to 64 KB.")
        }
    }

    /// `failureDescription` naming the value, e.g. "bot token".
    public func failureDescription(label: String) -> String? {
        switch self {
        case .success: return nil
        case .emptyValue: return "The \(label) was empty."
        default: return failureDescription.map { "The \(label) could not be saved. \($0)" }
        }
    }
}

extension Foundation.Notification.Name {
    /// Posted on the main queue after any credential, binding or metadata
    /// change. `userInfo["keys"]` lists the affected keys when known.
    public static let credentialsDidChange = Foundation.Notification.Name("CredentialsDidChange")
}
