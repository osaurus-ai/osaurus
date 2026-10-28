//
//  HarnessAdapter.swift
//  osaurus
//
//  The extension point for harness protocols. An adapter turns a runtime plus
//  a chat's launch context into a process to start, and a codec translates
//  that process's JSONL in both directions.
//

import Foundation

/// What Osaurus renders from a harness, in protocol-neutral form.
public enum HarnessEvent: Sendable, Equatable {
    case text(String)
    case reasoning(String)
    case toolStarted(callId: String?, name: String)
    case toolFinished(callId: String?, name: String, isError: Bool)
    /// A status line worth showing inline (retry, compaction, rate limit,
    /// extension notification).
    case notice(String, isError: Bool)
    /// The harness is blocked on a question for the user.
    case dialog(HarnessDialogRequest)
    case stats(outputTokens: Int, tokensPerSecond: Double, stopReason: String?)
    case turnCompleted
    case turnFailed(HarnessError)
}

public struct HarnessDialogRequest: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case select(options: [String])
        case confirm(message: String?)
        case input(placeholder: String?)
        case editor(prefill: String?)
    }

    public let id: String
    public let title: String
    public let kind: Kind

    public init(id: String, title: String, kind: Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

public enum HarnessDialogResponse: Sendable, Equatable {
    case value(String)
    case confirmed(Bool)
    case cancelled
}

public struct HarnessImage: Sendable, Equatable {
    public let data: Data
    public let mimeType: String

    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// The newest user message — the only thing a harness receives per turn; it
/// keeps its own history.
public struct HarnessUserMessage: Sendable, Equatable {
    public var text: String
    public var images: [HarnessImage]

    public init(text: String, images: [HarnessImage] = []) {
        self.text = text
        self.images = images
    }
}

/// Everything about a chat that decides how its harness process is started.
/// A change in any `fingerprint` field relaunches the process before the
/// next message.
struct HarnessLaunchContext: Sendable {
    enum SessionMode: Sendable, Equatable {
        /// Let the adapter decide whether there is a conversation to resume.
        case automatic
        case forceResume
        case forceNew
    }

    var runtime: HarnessRuntime
    var chatId: UUID
    var agentId: UUID
    var agentName: String
    var workingDirectory: URL
    /// True when `workingDirectory` is a user-selected folder rather than the
    /// per-chat scratch directory.
    var isUserFolder: Bool
    /// The agent's own persona/system prompt. Osaurus's composed agent prompt
    /// is never sent; the harness brings its own.
    var systemPrompt: String?
    var claudeCode: ClaudeCodeAgentConfig
    var osaurusCLIPath: String?
    var apiBase: String?
    var serverReachable: Bool
    var sessionMode: SessionMode = .automatic

    struct Fingerprint: Hashable {
        let runtime: HarnessRuntime
        let agentId: UUID
        let workingDirectory: String
        let systemPrompt: String?
        let claudeCode: ClaudeCodeAgentConfig
        let serverReachable: Bool
    }

    var fingerprint: Fingerprint {
        Fingerprint(
            runtime: runtime,
            agentId: agentId,
            workingDirectory: workingDirectory.standardizedFileURL.path,
            systemPrompt: systemPrompt,
            claudeCode: claudeCode,
            serverReachable: serverReachable
        )
    }
}

/// What to start, plus files to delete when the process is gone.
struct HarnessLaunchPlan: Sendable {
    var spec: HarnessProcess.LaunchSpec
    var temporaryFiles: [URL] = []
}

/// The documented environment every harness process receives.
enum HarnessEnvironment {
    static let chatId = "OSAURUS_CHAT_ID"
    static let agentId = "OSAURUS_AGENT_ID"
    static let agentToken = "OSAURUS_AGENT_TOKEN"
    static let apiBase = "OSAURUS_API_BASE"
    static let workingDirectory = "OSAURUS_WORKING_DIRECTORY"
    static let bridgeGrant = HarnessGrantStore.environmentKey

    /// Inherited variables no harness should see. `CLAUDECODE` makes a nested
    /// `claude` refuse to start; the bridge grant must only ever be the one
    /// Osaurus minted for this process.
    static let alwaysRemoved: Set<String> = ["CLAUDECODE", HarnessGrantStore.environmentKey]

    static func contract(context: HarnessLaunchContext, token: String?) -> [String: String] {
        var env: [String: String] = [
            chatId: context.chatId.uuidString.lowercased(),
            agentId: context.agentId.uuidString.lowercased(),
            workingDirectory: context.workingDirectory.path,
        ]
        if let apiBase = context.apiBase { env[Self.apiBase] = apiBase }
        if let token {
            env[agentToken] = token
            env[bridgeGrant] = token
        }
        return env
    }
}

protocol HarnessAdapter: Sendable {
    var runtime: HarnessRuntime { get }

    /// Tool scope for this process's agent token: nil defers to the agent's
    /// tool policy; a set is an exact allow-list (empty = MCP refused).
    func tokenToolScope(context: HarnessLaunchContext) -> Set<String>?
    func tokenAllowsConfigWrites(context: HarnessLaunchContext) -> Bool

    func launchPlan(context: HarnessLaunchContext, token: String?) throws -> HarnessLaunchPlan
    func makeCodec() -> HarnessCodec

    /// After a fresh process fails its first turn: the session mode to retry
    /// with once, or nil to surface the failure.
    func retryMode(after error: HarnessError, context: HarnessLaunchContext) -> HarnessLaunchContext.SessionMode?
}

extension HarnessAdapter {
    func retryMode(after error: HarnessError, context: HarnessLaunchContext) -> HarnessLaunchContext.SessionMode? {
        nil
    }
}

/// Per-process protocol state. Owned and driven by one `HarnessSession`.
protocol HarnessCodec: AnyObject {
    /// Records that start a turn.
    func beginTurn(_ message: HarnessUserMessage) throws -> [Data]
    /// Decode one stdout record into events, plus any records the protocol
    /// requires writing back.
    func decode(line: Data) -> (events: [HarnessEvent], replies: [Data])
    /// Records that stop the running turn.
    func interruptRecords() -> [Data]
    func dialogResponse(id: String, response: HarnessDialogResponse) -> Data?
    /// Dialogs the harness is still waiting on.
    var pendingDialogIds: [String] { get }
}

enum HarnessAdapters {
    static func adapter(for runtime: HarnessRuntime) -> HarnessAdapter {
        switch runtime.kind {
        case .claudeCode: return ClaudeCodeHarnessAdapter(runtime: runtime)
        case .piRPC: return PiRPCAdapter(runtime: runtime)
        }
    }
}

enum HarnessJSON {
    static func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    }

    static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }
}
