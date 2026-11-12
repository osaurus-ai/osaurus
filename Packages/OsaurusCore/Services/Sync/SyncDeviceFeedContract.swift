//
//  SyncDeviceFeedContract.swift
//  osaurus
//
//  App data for what an iPhone does with a Mac besides chatting
//  (docs/SYNC_MOBILE_CONTRACT.md): the Mac's attention feed, and managing
//  its agents. Each lives in one synced conversation per Mac, tagged
//  `ai.osaurus.kind` and `ai.osaurus.device` like the agent directory.
//  The Mac writes the state namespaces; the user's iPhones write the
//  answer and request namespaces.
//

import Foundation
import OsaurusSync

enum SyncDeviceFeedContract {
    static let attentionKind = "attention"
    static let manageKind = "manage"

    /// Mac: what needs the user, and what was settled recently.
    static let attentionNamespace = "ai.osaurus.attention/1"
    /// iPhone: answers to attention items. One namespace per iPhone,
    /// `<prefix><device key>`; the unsuffixed one is read for one release.
    static let attentionAnswerNamespace = "ai.osaurus.attention-answer/1"
    static let attentionAnswerNamespacePrefix = "ai.osaurus.attention-answer/1/"
    /// Mac: its agents and chat models.
    static let manageStateNamespace = "ai.osaurus.manage-state/1"
    /// iPhone: changes to make. Per iPhone like the attention answers.
    static let manageRequestNamespace = "ai.osaurus.manage-request/1"
    static let manageRequestNamespacePrefix = "ai.osaurus.manage-request/1/"
    /// Mac: how each change went, per requesting iPhone.
    static let manageResultNamespace = "ai.osaurus.manage-result/1"
    static let manageResultNamespacePrefix = "ai.osaurus.manage-result/1/"

    static func attentionAnswerNamespace(device: String) -> String { attentionAnswerNamespacePrefix + device }
    static func manageRequestNamespace(device: String) -> String { manageRequestNamespacePrefix + device }
    static func manageResultNamespace(device: String) -> String { manageResultNamespacePrefix + device }

    /// What this build does beyond `docs/SYNC_MOBILE_CONTRACT.md` v1, listed
    /// in the agent directory so an iPhone checks before relying on it.
    static let features = [
        "per_device_answers",
        "presence",
        "host_run_options",
        "run_progress",
        "context_usage",
        "manage_models",
        "agent_detail",
        "set_tool",
        "warm",
        "attention_detail",
        "privacy_review",
        "image_runs",
        "workspace_agents",
        "artifact_blobs",
        "history_filters",
        "continue_own_chats",
        "workflow_forms",
        "workflow_runs",
        "workflow_library",
        "workflow_outputs",
        "workflow_details",
        "workflow_push",
    ]

    /// Each device's record under `prefix`, keyed by device key.
    static func perDevice<T: Decodable>(_ type: T.Type, prefix: String, in conversation: Conversation) -> [String: T] {
        var result: [String: T] = [:]
        for entry in conversation.appData where entry.namespace.hasPrefix(prefix) {
            let device = String(entry.namespace.dropFirst(prefix.count))
            guard !device.isEmpty, let decoded = try? JSONDecoder().decode(type, from: entry.bytes) else { continue }
            result[device] = decoded
        }
        return result
    }

    /// Names of the user's other devices that are still in the account.
    static func deviceNames(_ devices: [Device]) -> [String: String] {
        var names: [String: String] = [:]
        for device in devices where !device.isSelf && !device.revoked {
            names[device.id] = device.name.isEmpty ? L("Your iPhone") : device.name
        }
        return names
    }

    /// Settled items the attention feed keeps after the pending ones.
    static let recentLimit = 20
    /// Requests and answers older than this are ignored.
    static let requestTTLMs: Int64 = 24 * 3600 * 1000

    // MARK: - Attention

    /// `action` is one the item offers: `approve`, `deny`,
    /// `allow_for_conversation`, `reply` (with `text`) or `dismiss`; or
    /// `submit` (with `values`) for a `workflow_dialog` that carries its form.
    struct AttentionAnswer: Codable, Equatable, Sendable {
        var action: String
        var text: String?
        /// `privacy_review` with `approve`: the detections to replace with
        /// their placeholders. Missing redacts every detection.
        var redact: [String]?
        /// `submit`: the form's answers by field key.
        var values: [String: JSONValue]?
        var answeredMs: Int64

        init(
            action: String, text: String? = nil, redact: [String]? = nil, values: [String: JSONValue]? = nil,
            answeredMs: Int64
        ) {
            self.action = action
            self.text = text
            self.redact = redact
            self.values = values
            self.answeredMs = answeredMs
        }
    }

    /// The answer that fills in a workflow form from the iPhone.
    static let submitAction = "submit"

    struct AttentionAnswers: Codable, Equatable, Sendable {
        var v: Int = 1
        var answers: [String: AttentionAnswer]

        init(answers: [String: AttentionAnswer]) {
            self.answers = answers
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            v = try container.decodeIfPresent(Int.self, forKey: .v) ?? 1
            let raw = try container.decodeIfPresent([String: Lenient<AttentionAnswer>].self, forKey: .answers) ?? [:]
            answers = raw.compactMapValues(\.value)
        }
    }

    static func outcome(for action: String) -> AttentionResolution.Outcome? {
        switch action {
        case "approve": return .approved
        case "deny": return .denied
        case "allow_for_conversation": return .allowedForConversation
        case "reply": return .replied
        case "dismiss": return .dismissed
        case "approve_rest": return .allowedForConversation
        default: return nil
        }
    }

    // MARK: - Managing agents

    struct ManagedAgent: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var description: String?
        var avatar: String?
        /// The Mac's Default agent: its model can change, nothing else.
        var isDefault: Bool?
        /// The model it runs, after defaults.
        var model: String?
        /// Nil for the Default agent.
        var settings: PhoneAgentEditing.Settings?
    }

    struct ManagedModel: Codable, Equatable, Sendable {
        var id: String
        var name: String
        var provider: String
    }

    /// A teammate's agent shared to one of this Mac's workspaces, which the
    /// iPhone can chat with through this Mac (`workspaceAgent` on a session).
    struct WorkspaceAgent: Codable, Equatable, Sendable {
        var workspaceId: String
        var workspaceName: String
        /// The agent's address, as `AgentRef` names it.
        var address: String
        var name: String
        var ownerName: String?
        var avatar: String?
    }

    /// A filter the Mac's chat history offers: a project, a plugin or a
    /// workspace, as `GET /projects` lists them.
    struct HistoryFilter: Codable, Equatable, Sendable {
        var id: String
        var name: String
    }

    struct ManageState: Codable, Equatable, Sendable {
        var v: Int = 1
        var device: String
        var agents: [ManagedAgent]
        var models: [ManagedModel]
        var workspaceAgents: [WorkspaceAgent]?
        /// Matched against a chat's `projectId`, `sourcePluginId` and
        /// `workspace.workspaceId`.
        var projects: [HistoryFilter]?
        var plugins: [HistoryFilter]?
        var workspaces: [HistoryFilter]?
        /// Installed workflows and their input forms (`workflow_library`).
        var workflows: [ManagedWorkflow]?
        /// The iPhones this Mac holds a push registration for (`workflow_push`), by device key.
        var pushRegistered: [String]?
        var updatedMs: Int64
    }

    // MARK: Models and agent detail (messages in the manage conversation)

    /// Message app data on the manage conversation's models message: every
    /// model the Mac's picker lists, with `/models/picker`'s fields, and its
    /// favourites. `models` is a blob reference (`{"$blob": 0, "size": n}`)
    /// when the list is too large to sit inline.
    static let manageModelsNamespace = "ai.osaurus.manage-models/1"
    /// Message app data on an agent's detail message: what the agent list
    /// leaves out (system prompt, avatar image, tools).
    static let agentDetailNamespace = "ai.osaurus.agent-detail/1"
    /// Content of those messages, so they're never taken for chat.
    static let modelsMessageContent = "models"
    static let agentDetailMessageContent = "agent"

    // MARK: Requests

    struct ManageRequest: Codable, Equatable, Sendable {
        enum Op: String, Codable, Sendable {
            case createAgent, updateAgent, setModel, setToolPreset, deleteAgent
            /// Heart or unheart a model: `key` (the row's `favorite_key`), `favorite`.
            case setFavorite
            /// `model`: answers with its options (`data`), as `/models/options` does.
            case getModelOptions
            /// `model`, `option`, `value` (a segment id or a bool; `clearValue` resets).
            case setModelOption
            /// `agentId`, `name` (the tool), and any of `enabled`, `agentEnabled`, `policy`.
            case setTool
            /// `agentId`, optional `model`: loads the model ahead of a voice call.
            case warm
            /// `scope` (the chat), `agentId`, optional `model`: writes the chat's
            /// `ai.osaurus.context-usage/1` and answers with it.
            case contextUsage
            /// `workflowId`, `input` (the form's values): starts the workflow and answers with its `runId`.
            case runWorkflow
            /// `runId`: writes a finished run's output message (§5.5) and answers once it's written.
            case workflowOutput
            /// An op this Mac's build doesn't know.
            case unsupported

            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Op(rawValue: raw).flatMap { $0 == .unsupported ? nil : $0 } ?? .unsupported
            }
        }

        var id: String
        var op: Op
        var agentId: String?
        var name: String?
        var description: String?
        var systemPrompt: String?
        var toolsEnabled: Bool?
        var memoryEnabled: Bool?
        var webSearchEnabled: Bool?
        var autonomousExecEnabled: Bool?
        var temperature: Float?
        var clearTemperature: Bool?
        var maxTokens: Int?
        var clearMaxTokens: Bool?
        /// `setModel`: nil or empty goes back to the default.
        var model: String?
        /// `setToolPreset`: `all`, `essential` or `none`.
        var preset: String?
        /// `setFavorite`
        var key: String?
        var favorite: Bool?
        /// `setModelOption`
        var option: String?
        var value: JSONValue?
        var clearValue: Bool?
        /// `setTool`: Mac-wide on/off, the agent's own choice, `auto | ask | deny`.
        var enabled: Bool?
        var agentEnabled: Bool?
        var policy: String?
        /// `contextUsage`: the chat's conversation scope.
        var scope: String?
        /// `runWorkflow`
        var workflowId: String?
        var input: JSONValue?
        /// `workflowOutput`
        var runId: String?
        var requestedMs: Int64

        init(
            id: String, op: Op, agentId: String? = nil, name: String? = nil, description: String? = nil,
            systemPrompt: String? = nil, model: String? = nil, preset: String? = nil, key: String? = nil,
            favorite: Bool? = nil, option: String? = nil, value: JSONValue? = nil, enabled: Bool? = nil,
            agentEnabled: Bool? = nil, policy: String? = nil, scope: String? = nil, requestedMs: Int64
        ) {
            self.id = id
            self.op = op
            self.agentId = agentId
            self.name = name
            self.description = description
            self.systemPrompt = systemPrompt
            self.model = model
            self.preset = preset
            self.key = key
            self.favorite = favorite
            self.option = option
            self.value = value
            self.enabled = enabled
            self.agentEnabled = agentEnabled
            self.policy = policy
            self.scope = scope
            self.requestedMs = requestedMs
        }
    }

    struct ManageRequests: Codable, Equatable, Sendable {
        var v: Int = 1
        var requests: [ManageRequest]

        init(requests: [ManageRequest]) {
            self.requests = requests
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            v = try container.decodeIfPresent(Int.self, forKey: .v) ?? 1
            let raw = try container.decodeIfPresent([Lenient<ManageRequest>].self, forKey: .requests) ?? []
            requests = raw.compactMap(\.value)
        }
    }

    struct ManageResult: Codable, Equatable, Sendable {
        var ok: Bool
        /// `agent_not_editable`, `bad_request`, `sandbox_unavailable`,
        /// `agent_shared`, `tools_loading`, `agent_not_found`, `interrupted`,
        /// `failed`.
        var error: String?
        var message: String?
        /// The new agent's id, for `createAgent`.
        var agentId: String?
        /// What a read op answers with (`getModelOptions`, `setModelOption`,
        /// `setTool`, `warm`, `contextUsage`).
        var data: JSONValue?
        var doneMs: Int64

        init(
            ok: Bool, error: String? = nil, message: String? = nil, agentId: String? = nil, data: JSONValue? = nil,
            doneMs: Int64
        ) {
            self.ok = ok
            self.error = error
            self.message = message
            self.agentId = agentId
            self.data = data
            self.doneMs = doneMs
        }
    }

    /// Longest `data` a result carries; larger answers fail with `too_large`.
    static let resultDataLimit = 16 * 1024

    struct ManageResults: Codable, Equatable, Sendable {
        var v: Int = 1
        var results: [String: ManageResult]
    }

    // MARK: - Conversations

    /// A record a newer version spells differently decodes to nil.
    struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    /// This device's conversation of `kind`, if it made one.
    static func conversation(kind: String, device: String, core: SyncCore) throws -> Conversation? {
        let filter = ConversationFilter(
            tags: [
                Tag(key: SyncConversationMapper.TagKey.kind, value: kind),
                Tag(key: SyncConversationMapper.TagKey.device, value: device),
            ],
            limit: 1
        )
        return try core.conversationsFiltered(filter: filter).first
    }

    /// This device's conversation of `kind`, made when missing.
    static func ensureConversation(kind: String, title: String, core: SyncCore) throws -> String {
        let me = core.deviceKey()
        if let existing = try conversation(kind: kind, device: me, core: core) { return existing.scope }
        let scope = try core.createConversation(title: title, replication: .synced)
        try core.setConversationTags(
            scope: scope,
            tags: [
                Tag(key: SyncConversationMapper.TagKey.device, value: me),
                Tag(key: SyncConversationMapper.TagKey.kind, value: kind),
            ].sorted { $0.key < $1.key }
        )
        offerSystemConversationsFirst(core: core)
        return scope
    }

    /// This Mac's agent directory goes to a catching-up iPhone before any chat: it can't list agents
    /// or open a chat without it, and on an account with hundreds of chats it otherwise waited behind
    /// them (`setOfferFirst`). Only the directory: the manage and attention conversations keep every
    /// request, result and change ever written, and offered first, a new iPhone spent its first
    /// minutes on their history while its recent chats waited. Called when the core opens and when
    /// one of them is made.
    nonisolated static func offerSystemConversationsFirst(core: SyncCore) {
        let me = core.deviceKey()
        let kinds = [SyncHostedRunContract.directoryKind]
        let scopes = kinds.compactMap { kind in (try? conversation(kind: kind, device: me, core: core))?.scope }
        // Fails only on a closed core; the next open sets it again.
        try? core.setOfferFirst(scopes: scopes)
    }
}
