//
//  WorkflowDraft.swift
//  osaurus
//
//  An unsaved workflow the Architect is building in one chat. The draft is
//  the source of truth for the sidebar graph, the node editor, and test
//  runs; saving turns it into a template version. Edits come from two
//  places: the Architect's `workflow_draft` patch ops, and the user's direct
//  edits in the sidebar. Direct edits are summarized and handed to the
//  Architect with the user's next message so it never works from a stale
//  picture.
//

import Foundation

public struct WorkflowDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    /// The chat this draft belongs to.
    public var sessionID: String?
    public var name: String
    public var summary: String
    /// Set when the draft edits an existing template; saving makes a new
    /// version of it. Nil until the first save of a new workflow.
    public var templateID: UUID?
    /// The template version the draft started from.
    public var baseVersion: Int?
    public var definition: WorkflowDefinition
    /// Models and secrets test runs use on this Mac.
    public var bindings: InstallBindings
    /// Server setup carried from the template the draft started from.
    public var serverHints: [MCPServerHint] = []
    /// Snapshots before each edit, newest last, for undo.
    public var history: [WorkflowDraftEdit]
    public var testRunIDs: [UUID]
    /// Nodes the last Architect patch touched, highlighted in the graph.
    public var lastPatchedNodeIDs: [String]
    /// The user's direct edits since the Architect last saw the draft.
    public var pendingUserEdits: [String]
    /// The node selected in the sidebar, sent as context with the next turn.
    public var selectedNodeID: String?
    /// The failed run the Architect was asked to fix ("Fix with the
    /// Architect" or self-heal). `workflow_runs` and `workflow_test`
    /// default to it.
    public var repairRunID: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public static let historyLimit = 50

    public init(
        id: UUID = UUID(), sessionID: String? = nil, name: String = "", summary: String = "",
        templateID: UUID? = nil, baseVersion: Int? = nil, definition: WorkflowDefinition = WorkflowDefinition(),
        bindings: InstallBindings = InstallBindings()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.name = name
        self.summary = summary
        self.templateID = templateID
        self.baseVersion = baseVersion
        self.definition = definition
        self.bindings = bindings
        self.history = []
        self.testRunIDs = []
        self.lastPatchedNodeIDs = []
        self.pendingUserEdits = []
        self.selectedNodeID = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, definition, bindings, history
        case serverHints = "server_hints"
        case sessionID = "session_id"
        case templateID = "template_id"
        case baseVersion = "base_version"
        case testRunIDs = "test_run_ids"
        case lastPatchedNodeIDs = "last_patched_node_ids"
        case pendingUserEdits = "pending_user_edits"
        case selectedNodeID = "selected_node_id"
        case repairRunID = "repair_run_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        templateID = try c.decodeIfPresent(UUID.self, forKey: .templateID)
        baseVersion = try c.decodeIfPresent(Int.self, forKey: .baseVersion)
        definition = try c.decodeIfPresent(WorkflowDefinition.self, forKey: .definition) ?? WorkflowDefinition()
        bindings = try c.decodeIfPresent(InstallBindings.self, forKey: .bindings) ?? InstallBindings()
        serverHints = try c.decodeIfPresent([MCPServerHint].self, forKey: .serverHints) ?? []
        history = try c.decodeIfPresent([WorkflowDraftEdit].self, forKey: .history) ?? []
        testRunIDs = try c.decodeIfPresent([UUID].self, forKey: .testRunIDs) ?? []
        lastPatchedNodeIDs = try c.decodeIfPresent([String].self, forKey: .lastPatchedNodeIDs) ?? []
        pendingUserEdits = try c.decodeIfPresent([String].self, forKey: .pendingUserEdits) ?? []
        selectedNodeID = try c.decodeIfPresent(String.self, forKey: .selectedNodeID)
        repairRunID = try c.decodeIfPresent(UUID.self, forKey: .repairRunID)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    /// The template a save or test run uses. A new draft's template takes
    /// the draft's id.
    public func template(changelog: String = "") -> Template {
        Template(
            id: templateID ?? id,
            version: baseVersion ?? 1,
            changelog: changelog,
            name: name.isEmpty ? L("Untitled workflow") : name,
            summary: summary.isEmpty ? nil : summary,
            payload: .workflow(definition),
            serverHints: serverHints)
    }

    /// Records the draft's content for undo, then applies `change`. The
    /// snapshot covers everything a save reads — definition, name,
    /// summary, which saved workflow and version it continues, bindings,
    /// server hints — so undoing past a rebase or a detach puts all of it
    /// back together, not an older definition under a newer base version.
    mutating func edit(source: WorkflowDraftEdit.Source, summary: String, _ change: (inout WorkflowDraft) -> Void) {
        history.append(WorkflowDraftEdit(source: source, summary: summary, before: self))
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        change(&self)
        updatedAt = Date()
    }

    /// Restores the draft as it was before the most recent edit.
    @discardableResult
    mutating func undo() -> WorkflowDraftEdit? {
        guard let last = history.popLast() else { return nil }
        definition = last.definition
        name = last.name
        if let summary = last.draftSummary { self.summary = summary }
        // Snapshots written before these fields were recorded leave them
        // as they are; new ones restore them even when nil (a detach).
        if last.recordsIdentity {
            templateID = last.templateID
            baseVersion = last.baseVersion
        }
        // Bindings are the user's choices on this Mac and are set outside
        // the edit history, so undo keeps what is bound now and only
        // brings back entries the snapshot had that are gone.
        if let bindings = last.bindings {
            self.bindings.models.merge(bindings.models) { current, _ in current }
            self.bindings.secrets.merge(bindings.secrets) { current, _ in current }
            self.bindings.mcpServers.merge(bindings.mcpServers) { current, _ in current }
            self.bindings.plugins.merge(bindings.plugins) { current, _ in current }
            self.bindings.folders.merge(bindings.folders) { current, _ in current }
        }
        if let hints = last.serverHints { serverHints = hints }
        updatedAt = Date()
        return last
    }

    /// Forgets which saved workflow the history continued, so undoing past
    /// a detach cannot rebind the draft to it.
    mutating func forgetSavedIdentityInHistory() {
        for i in history.indices {
            history[i].templateID = nil
            history[i].baseVersion = nil
        }
    }
}

public struct WorkflowDraftEdit: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable {
        case architect
        case user
    }

    public var at: Date
    public var source: Source
    public var summary: String
    /// Name and definition before the edit.
    public var name: String
    public var definition: WorkflowDefinition
    /// The draft's own summary text before the edit (`summary` above is
    /// what changed). Nil in history written before it was recorded.
    public var draftSummary: String?
    /// Which saved workflow and version the draft continued before the
    /// edit. `recordsIdentity` tells a recorded nil from an old snapshot.
    public var templateID: UUID?
    public var baseVersion: Int?
    public var recordsIdentity: Bool
    public var bindings: InstallBindings?
    public var serverHints: [MCPServerHint]?
    /// Why the Architect made the change, in its words, when it said.
    public var why: String?
    /// The diff lines behind `summary`, one per change, for review.
    public var lines: [String]

    public init(source: Source, summary: String, name: String, definition: WorkflowDefinition) {
        self.at = Date()
        self.source = source
        self.summary = summary
        self.name = name
        self.definition = definition
        self.recordsIdentity = false
        self.lines = []
    }

    public init(source: Source, summary: String, before draft: WorkflowDraft) {
        self.at = Date()
        self.source = source
        self.summary = summary
        self.name = draft.name
        self.definition = draft.definition
        self.draftSummary = draft.summary
        self.templateID = draft.templateID
        self.baseVersion = draft.baseVersion
        self.recordsIdentity = true
        self.bindings = draft.bindings
        self.serverHints = draft.serverHints
        self.lines = []
    }

    enum CodingKeys: String, CodingKey {
        case at, source, summary, name, definition, bindings, why, lines
        case draftSummary = "draft_summary"
        case templateID = "template_id"
        case baseVersion = "base_version"
        case recordsIdentity = "records_identity"
        case serverHints = "server_hints"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .user
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        definition = try c.decodeIfPresent(WorkflowDefinition.self, forKey: .definition) ?? WorkflowDefinition()
        draftSummary = try c.decodeIfPresent(String.self, forKey: .draftSummary)
        templateID = try c.decodeIfPresent(UUID.self, forKey: .templateID)
        baseVersion = try c.decodeIfPresent(Int.self, forKey: .baseVersion)
        recordsIdentity = try c.decodeIfPresent(Bool.self, forKey: .recordsIdentity) ?? false
        bindings = try c.decodeIfPresent(InstallBindings.self, forKey: .bindings)
        serverHints = try c.decodeIfPresent([MCPServerHint].self, forKey: .serverHints)
        why = try c.decodeIfPresent(String.self, forKey: .why)
        lines = try c.decodeIfPresent([String].self, forKey: .lines) ?? []
    }
}

// MARK: - Patch ops

/// One `workflow_draft` patch operation. Ops in a call apply together: if
/// any fails, the draft is unchanged.
public enum WorkflowDraftOp: Equatable, Sendable {
    case planPlaceholder(id: String, name: String, intent: String)
    /// Shallow merge of `fields` over the node's JSON.
    case updateNode(id: String, fields: [String: JSONValue])
    case removeNode(id: String)
    case addEdge(WorkflowEdge)
    case removeEdge(from: String, to: String)
    case setSchemas(input: JSONValue?, output: JSONValue?)
    case setOutput(WorkflowBinding)
    case setInfo(name: String?, summary: String?)
    case declareSlot(ModelRequirement)
    case declareSecret(SecretRequirement)
    /// Upsert by manager; an empty `packages` removes the manager's entry.
    case declareDependency(WorkflowDependency)
    /// Upsert by key.
    case declareFolder(FolderRequirement)
    case removeFolder(key: String)
    /// Upsert by name.
    case addExample(WorkflowExample)
    case removeExample(name: String)
    /// Upsert by name: the MCP server a step uses, so setup can connect
    /// it on another Mac. `remove` drops the hint.
    case declareServer(MCPServerHint, remove: Bool)
    /// The draft stops being the next version of the saved workflow it was
    /// opened from and saves as a new workflow.
    case detach

    public static let names = [
        "plan_placeholder", "update_node", "remove_node", "add_edge", "remove_edge",
        "set_schemas", "set_output", "set_info", "declare_slot", "declare_secret", "declare_connection",
        "declare_dependency", "declare_folder", "add_example", "declare_server", "detach",
    ]

    public struct ParseError: Error, Equatable {
        public var message: String
    }

    /// `declare_connection`: a login to a service as one secret. With a
    /// `provider` from the catalog the endpoints, scopes, label, and help
    /// are filled in; `sign_in: false` asks for a personal token instead
    /// of the browser sign-in. Without a provider, `service` names the
    /// host and `oauth2` (optional) the sign-in.
    static func parseConnection(_ o: [String: JSONValue], decode: (JSONValue) throws -> OAuth2Spec) throws
        -> SecretRequirement
    {
        let providerID = o["provider"]?.stringValue?.trimmingCharacters(in: .whitespaces).lowercased()
        var provider: ConnectionProvider?
        if let providerID, !providerID.isEmpty {
            guard let found = ConnectionProviders.provider(id: providerID) else {
                throw ParseError(
                    message:
                        "`declare_connection` provider `\(providerID)` is not in the catalog. Known: "
                        + "\(ConnectionProviders.all.map(\.id).joined(separator: ", ")). For another service give "
                        + "`service` (its API host) and, for a sign-in, `oauth2`.")
            }
            provider = found
        }
        let service = o["service"]?.stringValue?.trimmingCharacters(in: .whitespaces).lowercased()
        guard provider != nil || (service?.isEmpty == false) else {
            throw ParseError(message: "`declare_connection` needs a `provider` from the catalog or a `service` host.")
        }
        let defaultKey = (provider?.id ?? service ?? "service")
            .uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let key = o["key"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        let finalKey = (key?.isEmpty == false ? key! : String(defaultKey) + "_TOKEN")
        let wantsSignIn = o["sign_in"]?.boolValue ?? true
        var oauth2: OAuth2Spec?
        if let explicit = o["oauth2"], explicit != .null {
            oauth2 = try decode(explicit)
        } else if wantsSignIn, let spec = provider?.oauth2 {
            oauth2 = spec
        }
        if let scopes = o["scopes"]?.arrayValue?.compactMap(\.stringValue), !scopes.isEmpty {
            oauth2?.scopes = scopes
        }
        if let provider, provider.requiresScopes, let oauth2, oauth2.scopes.isEmpty {
            throw ParseError(
                message:
                    "`declare_connection` \(provider.name) needs `scopes`: the sign-in is refused without at least one "
                    + "(for example https://www.googleapis.com/auth/gmail.readonly).")
        }
        if let provider, oauth2 == nil, !provider.supportsToken {
            throw ParseError(
                message: "`declare_connection` \(provider.name) issues no personal tokens; use the sign-in (`sign_in: true`).")
        }
        let serviceName = provider?.name ?? service ?? ""
        let label = o["label"]?.stringValue?.trimmingCharacters(in: .whitespaces)
        let help = o["help"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultHelp: String? = {
            guard let provider else { return nil }
            return oauth2 != nil ? provider.oauthHelp : provider.tokenHelp
        }()
        return SecretRequirement(
            key: finalKey,
            label: label?.isEmpty == false ? label! : "\(serviceName) account",
            help: help?.isEmpty == false ? help : defaultHelp,
            oauth2: oauth2,
            service: provider?.service ?? service,
            provider: provider?.id)
    }

    public static func parse(_ value: JSONValue) throws -> WorkflowDraftOp {
        guard let o = value.objectValue, let op = o["op"]?.stringValue else {
            throw ParseError(message: "Each op needs an `op` string: one of \(names.joined(separator: ", ")).")
        }
        func string(_ key: String) throws -> String {
            guard let s = o[key]?.stringValue, !s.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ParseError(message: "`\(op)` needs a non-empty `\(key)` string.")
            }
            return s
        }
        func decode<T: Decodable>(_ type: T.Type, _ json: JSONValue, what: String) throws -> T {
            do {
                return try JSONDecoder().decode(T.self, from: Data(json.compactJSONString.utf8))
            } catch let DecodingError.dataCorrupted(ctx) {
                throw ParseError(message: "`\(op)` \(what): \(ctx.debugDescription)")
            } catch let DecodingError.keyNotFound(key, _) {
                throw ParseError(message: "`\(op)` \(what) is missing `\(key.stringValue)`.")
            } catch let DecodingError.typeMismatch(_, ctx) {
                let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
                throw ParseError(message: "`\(op)` \(what) has the wrong type at `\(path)`.")
            } catch {
                throw ParseError(message: "`\(op)` \(what) is invalid: \(error.localizedDescription)")
            }
        }
        switch op {
        case "plan_placeholder":
            // Like `update_node`, the id and name may sit inside `node`.
            let inner = o["node"]?.objectValue ?? [:]
            let id = (o["id"] ?? inner["id"])?.stringValue ?? ""
            guard !id.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ParseError(message: "`plan_placeholder` needs a non-empty `id` string.")
            }
            let name = (o["name"] ?? inner["name"])?.stringValue ?? ""
            let intent = (o["intent"] ?? inner["intent"])?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let said = [intent ?? "", name].first { !$0.isEmpty } ?? id
            return .planPlaceholder(id: id, name: name, intent: said)
        case "update_node":
            guard let fields = o["node"]?.objectValue ?? o["fields"]?.objectValue else {
                throw ParseError(message: "`update_node` needs `id` and a `node` object with the fields to change.")
            }
            let stray = o.keys.filter { !["op", "id", "node", "fields"].contains($0) }.sorted()
            let isFieldName = { (key: String) in
                key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
            }
            let misplaced = stray.filter(isFieldName)
            let junk = stray.filter { !isFieldName($0) }
            if !junk.isEmpty {
                throw ParseError(
                    message: "`update_node` has keys that are not fields: "
                        + junk.map { "`\($0)`" }.joined(separator: ", ")
                        + ". An op is `{op, id, node}`; remove them.")
            }
            if !misplaced.isEmpty {
                throw ParseError(
                    message: "`update_node` takes the fields to change inside `node`; move "
                        + misplaced.map { "`\($0)`" }.joined(separator: ", ") + " into `node`.")
            }
            // The target is the op's `id`, or the `id` inside `node`.
            if o["id"]?.stringValue == nil, let target = fields["id"]?.stringValue,
                !target.trimmingCharacters(in: .whitespaces).isEmpty
            {
                return .updateNode(id: target, fields: fields)
            }
            return .updateNode(id: try string("id"), fields: fields)
        case "remove_node":
            return .removeNode(id: try string("id"))
        case "add_edge":
            var edge = WorkflowEdge(from: try string("from"), to: try string("to"))
            if let when = o["when"], when != .null { edge.when = try decode(WorkflowCondition.self, when, what: "`when`") }
            if let on = o["on"]?.stringValue {
                guard let trigger = WorkflowEdge.Trigger(rawValue: on) else {
                    throw ParseError(message: "`on` must be \"success\", \"error\", or \"always\".")
                }
                edge.on = trigger
            }
            return .addEdge(edge)
        case "remove_edge":
            return .removeEdge(from: try string("from"), to: try string("to"))
        case "set_schemas":
            let input = o["input_schema"], output = o["output_schema"]
            guard input != nil || output != nil else {
                throw ParseError(message: "`set_schemas` needs `input_schema`, `output_schema`, or both.")
            }
            return .setSchemas(input: input, output: output)
        case "set_output":
            guard let output = o["output"] else { throw ParseError(message: "`set_output` needs `output`.") }
            return .setOutput(try decode(WorkflowBinding.self, output, what: "`output`"))
        case "set_info":
            return .setInfo(name: o["name"]?.stringValue, summary: o["summary"]?.stringValue)
        case "declare_slot":
            return .declareSlot(try decode(ModelRequirement.self, value, what: "slot"))
        case "declare_secret":
            return .declareSecret(try decode(SecretRequirement.self, value, what: "secret"))
        case "declare_connection":
            return .declareSecret(try parseConnection(o, decode: { try decode(OAuth2Spec.self, $0, what: "`oauth2`") }))
        case "declare_dependency":
            let dependency = try decode(WorkflowDependency.self, value, what: "dependency")
            if !dependency.packages.isEmpty, let issue = dependency.issues.first {
                throw ParseError(message: "`declare_dependency` \(issue)")
            }
            return .declareDependency(dependency)
        case "declare_folder":
            let key = try string("key")
            if o["remove"] == .bool(true) { return .removeFolder(key: key) }
            let access: FolderRequirement.Access
            switch o["access"]?.stringValue {
            case nil: access = .write
            case let raw?:
                guard let parsed = FolderRequirement.Access(rawValue: raw) else {
                    throw ParseError(message: "`declare_folder` `access` must be `read` or `write`.")
                }
                access = parsed
            }
            let hint = o["hint"]?.stringValue.flatMap { $0.isEmpty ? nil : PathHint(path: $0) }
            let folder = FolderRequirement(
                key: key, label: o["label"]?.stringValue ?? "", help: o["help"]?.stringValue, access: access,
                hint: hint)
            if let issue = folder.issues.first {
                throw ParseError(message: "`declare_folder` \(issue)")
            }
            return .declareFolder(folder)
        case "add_example":
            if o["remove"]?.boolValue == true { return .removeExample(name: try string("name")) }
            guard let input = o["input"], case .object = input else {
                throw ParseError(message: "`add_example` needs `input`: an object matching the workflow's input schema.")
            }
            return .addExample(WorkflowExample(name: try string("name"), input: input))
        case "declare_server":
            let name = try string("name")
            if o["remove"]?.boolValue == true {
                return .declareServer(MCPServerHint(name: name), remove: true)
            }
            var hint = try decode(MCPServerHint.self, value, what: "server")
            hint.name = name
            if let directoryID = hint.directoryID, !directoryID.isEmpty {
                guard let entry = MCPProviderTemplate.allTemplates.first(where: { $0.id == directoryID }) else {
                    throw ParseError(message: "`declare_server` names directory id `\(directoryID)`, which is not in the Osaurus MCP Directory.")
                }
                if hint.url == nil || hint.url?.isEmpty == true { hint.url = entry.url }
                if hint.auth == nil { hint.auth = entry.authType }
            } else if hint.transport == .http {
                guard let url = hint.url, let parsed = URL(string: url), parsed.scheme?.lowercased() == "https" else {
                    throw ParseError(message: "`declare_server` needs an https `url` or a `directory_id`.")
                }
            } else if (hint.command ?? "").isEmpty {
                throw ParseError(message: "`declare_server` with transport `\(hint.transport.rawValue)` needs a `command`.")
            }
            return .declareServer(hint, remove: false)
        case "detach":
            return .detach
        default:
            throw ParseError(message: "Unknown op `\(op)`. Use one of \(names.joined(separator: ", ")).")
        }
    }
}

public enum WorkflowDraftPatcher {
    public struct Failure: Error, Equatable {
        public var index: Int
        public var message: String
    }

    public struct Result: Equatable {
        public var definition: WorkflowDefinition
        public var name: String?
        public var summary: String?
        /// Nodes added, changed, or planned by the ops.
        public var touchedNodeIDs: [String]
        /// The ops included `detach`.
        public var detached = false
        /// Server hints to upsert (by name) and names to remove, in order.
        public var serverHints: [(MCPServerHint, remove: Bool)] = []

        public static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.definition == rhs.definition && lhs.name == rhs.name && lhs.summary == rhs.summary
                && lhs.touchedNodeIDs == rhs.touchedNodeIDs && lhs.detached == rhs.detached
                && lhs.serverHints.map(\.0) == rhs.serverHints.map(\.0)
                && lhs.serverHints.map(\.remove) == rhs.serverHints.map(\.remove)
        }
    }

    /// Keys of an object schema's properties in the order a form shows
    /// them: `x-order` first, then `required` (an ordered array), then the
    /// rest alphabetically. Unknown keys in either list are dropped.
    public static func fieldOrder(_ schema: JSONValue) -> [String] {
        guard case .object(let root) = schema, case .object(let props)? = root["properties"] else { return [] }
        func strings(_ value: JSONValue?) -> [String] {
            guard case .array(let list)? = value else { return [] }
            return list.compactMap { if case .string(let s) = $0 { s } else { nil } }
        }
        var seen = Set<String>()
        return (strings(root["x-order"]) + strings(root["required"]) + props.keys.sorted())
            .filter { props[$0] != nil && seen.insert($0).inserted }
    }

    /// The input schema with `x-order` covering every property, so the run
    /// form's field order is the designer's, not the dictionary's.
    static func stampingFieldOrder(_ schema: JSONValue) -> JSONValue {
        guard case .object(var root) = schema, case .object? = root["properties"] else { return schema }
        root["x-order"] = .array(fieldOrder(schema).map { .string($0) })
        return .object(root)
    }

    public static func apply(_ ops: [WorkflowDraftOp], to start: WorkflowDefinition) throws -> Result {
        var def = start
        var name: String?
        var summary: String?
        var touched: [String] = []
        var detached = false
        var serverHints: [(MCPServerHint, remove: Bool)] = []
        var removedNodes: Set<String> = []
        func touch(_ id: String) { if !touched.contains(id) { touched.append(id) } }

        for (index, op) in ops.enumerated() {
            func fail(_ message: String) -> Failure { Failure(index: index, message: message) }
            switch op {
            case .planPlaceholder(let id, let nodeName, let intent):
                guard def.node(id) == nil else { throw fail("Node `\(id)` already exists.") }
                def.nodes.append(WorkflowNode(id: id, name: nodeName.isEmpty ? id : nodeName, intent: intent, kind: nil))
                touch(id)
            case .updateNode(let id, let fields):
                guard let i = def.nodes.firstIndex(where: { $0.id == id }) else {
                    throw fail("No node `\(id)`.")
                }
                if let newID = fields["id"]?.stringValue, newID != id {
                    throw fail("Node ids can't change. Remove `\(id)` and plan a new step with `plan_placeholder` instead.")
                }
                guard case .object(var merged) = encode(def.nodes[i]) else { throw fail("Node `\(id)` could not be read.") }
                for (key, value) in fields { merged[key] = value }
                if let kind = fields["kind"]?.stringValue, kind != def.nodes[i].kindName {
                    for other in WorkflowNode.kindNames where other != kind {
                        merged.removeValue(forKey: other)
                    }
                }
                def.nodes[i] = try decodeNode(.object(merged), index: index)
                touch(id)
            case .removeNode(let id):
                guard def.node(id) != nil else { throw fail("No node `\(id)`.") }
                def.nodes.removeAll { $0.id == id }
                def.edges.removeAll { $0.from == id || $0.to == id }
                removedNodes.insert(id)
            case .addEdge(let edge):
                for end in [edge.from, edge.to] where def.node(end) == nil {
                    throw fail("No node `\(end)` for edge \(edge.from) → \(edge.to).")
                }
                if let i = def.edges.firstIndex(where: { $0.from == edge.from && $0.to == edge.to }) {
                    def.edges[i] = edge
                } else {
                    def.edges.append(edge)
                }
            case .removeEdge(let from, let to):
                let before = def.edges.count
                def.edges.removeAll { $0.from == from && $0.to == to }
                // `remove_node` already dropped its edges.
                guard def.edges.count < before || removedNodes.contains(from) || removedNodes.contains(to) else {
                    throw fail("No edge \(from) → \(to).")
                }
            case .setSchemas(let input, let output):
                if let input { def.inputSchema = Self.stampingFieldOrder(input) }
                if let output { def.outputSchema = output }
            case .setOutput(let binding):
                def.output = binding
            case .setInfo(let newName, let newSummary):
                if let newName { name = newName }
                if let newSummary { summary = newSummary }
            case .declareSlot(let slot):
                if let i = def.modelSlots.firstIndex(where: { $0.slot == slot.slot }) {
                    def.modelSlots[i] = slot
                } else {
                    def.modelSlots.append(slot)
                }
            case .declareSecret(let secret):
                if let i = def.secrets.firstIndex(where: { $0.key == secret.key }) {
                    def.secrets[i] = secret
                } else {
                    def.secrets.append(secret)
                }
            case .declareDependency(let dependency):
                def.dependencies = WorkflowDependency.upserting(dependency, in: def.dependencies)
            case .declareFolder(let folder):
                def.folders = FolderRequirement.upserting(folder, in: def.folders)
            case .removeFolder(let key):
                guard def.folders.contains(where: { $0.key == key }) else { throw fail("No folder `\(key)`.") }
                def.folders.removeAll { $0.key == key }
            case .addExample(let example):
                def.examples.removeAll { $0.name == example.name }
                def.examples.append(example)
            case .removeExample(let exampleName):
                guard def.examples.contains(where: { $0.name == exampleName }) else {
                    throw fail("No example `\(exampleName)`.")
                }
                def.examples.removeAll { $0.name == exampleName }
            case .declareServer(let hint, let remove):
                serverHints.append((hint, remove: remove))
            case .detach:
                detached = true
            }
        }
        var result = Result(definition: def, name: name, summary: summary, touchedNodeIDs: touched, detached: detached)
        result.serverHints = serverHints
        return result
    }

    static func encode(_ node: WorkflowNode) -> JSONValue {
        guard let data = try? JSONEncoder().encode(node),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .null }
        return value
    }

    private static func decodeNode(_ json: JSONValue, index: Int) throws -> WorkflowNode {
        do {
            return try JSONDecoder().decode(WorkflowNode.self, from: Data(json.compactJSONString.utf8))
        } catch let DecodingError.dataCorrupted(ctx) {
            throw Failure(index: index, message: ctx.debugDescription)
        } catch let DecodingError.keyNotFound(key, ctx) {
            let path = (ctx.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: ".")
            throw Failure(index: index, message: "Node is missing `\(path)`.")
        } catch let DecodingError.typeMismatch(_, ctx) {
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            throw Failure(index: index, message: "Node has the wrong type at `\(path)`.")
        } catch {
            throw Failure(index: index, message: "Node is invalid: \(error.localizedDescription)")
        }
    }
}

// MARK: - Diff

/// Human-readable differences between two definitions. Used for the
/// direct-edit summary the Architect receives and for version history.
public enum WorkflowDiff {
    public struct Change: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable {
            case added, removed, changed
        }

        public var kind: Kind
        /// "node classify", "edge a → b", "input schema", ...
        public var subject: String
        /// Changed keys for a changed node.
        public var fields: [String]
        public var before: String?
        public var after: String?

        public var id: String { "\(kind.rawValue):\(subject)" }

        public var line: String {
            switch kind {
            case .added: return "Added \(subject)"
            case .removed: return "Removed \(subject)"
            case .changed:
                return fields.isEmpty ? "Changed \(subject)" : "Changed \(subject): \(fields.joined(separator: ", "))"
            }
        }
    }

    /// The changes in the person's words: steps by name, edges as
    /// "from → to" by step names, and field keys as what they mean
    /// ("instructions", "model", "arguments"). For the Changes list and the
    /// save card; `Change.line` stays the compact form for tool results.
    public static func plainLines(from old: WorkflowDefinition, to new: WorkflowDefinition) -> [String] {
        plainLines(changes(from: old, to: new, details: false), from: old, to: new)
    }

    /// `plainLines` for changes already computed between `old` and `new`.
    public static func plainLines(_ changes: [Change], from old: WorkflowDefinition, to new: WorkflowDefinition)
        -> [String]
    {
        func stepName(_ id: String) -> String {
            let name = new.node(id)?.name ?? old.node(id)?.name ?? id
            return "“\(name.isEmpty ? id : name)”"
        }
        func fieldName(_ key: String) -> String {
            switch key {
            case "name": return L("name")
            case "intent": return L("purpose")
            case "kind": return L("type")
            case "input": return L("inputs")
            case "output_schema": return L("result shape")
            case "timeout": return L("time limit")
            case "retry": return L("retries")
            case "inference": return L("model settings")
            case "http": return L("request")
            case "dialog": return L("form")
            case "map": return L("repetition")
            case "wait": return L("wait time")
            case "workflow": return L("workflow it runs")
            case "state": return L("stored data")
            case "inference.instructions": return L("instructions")
            case "inference.model_slot": return L("model")
            case "inference.mode": return L("mode")
            case "inference.temperature": return L("temperature")
            case "code.source": return L("code")
            case "code.language": return L("language")
            case "code.network": return L("hosts it reaches")
            case "code.secrets": return L("secrets")
            case "tool.tool": return L("tool")
            case "http.url": return L("URL")
            case "http.method": return L("method")
            case "http.headers": return L("headers")
            case "http.body": return L("request body")
            case "http.auth": return L("authentication")
            case "dialog.fields": return L("form fields")
            case "dialog.title", "dialog.message": return L("prompt text")
            case "map.items": return L("items")
            case "map.step": return L("repeated step")
            case "map.concurrency": return L("how many at a time")
            case "wait.seconds", "wait.until": return L("wait time")
            case "workflow.workflow": return L("workflow it runs")
            case "state.action": return L("stored-data action")
            case "state.table": return L("table")
            case "state.key": return L("key")
            case "state.value": return L("stored value")
            case "state.by": return L("count step")
            case "state.limit": return L("row limit")
            default:
                return key.split(separator: ".").last.map { String($0).replacingOccurrences(of: "_", with: " ") } ?? key
            }
        }
        return changes.map { change in
            if change.subject.hasPrefix("node ") {
                let id = String(change.subject.dropFirst("node ".count))
                switch change.kind {
                case .added: return L("Added step \(stepName(id))")
                case .removed: return L("Removed step \(stepName(id))")
                case .changed:
                    let fields = change.fields.map(fieldName)
                    var seen = Set<String>()
                    let unique = fields.filter { seen.insert($0).inserted }
                    return unique.isEmpty
                        ? L("Changed step \(stepName(id))")
                        : L("Changed step \(stepName(id)): \(unique.joined(separator: ", "))")
                }
            }
            if change.subject.hasPrefix("edge ") {
                let parts = change.subject.dropFirst("edge ".count).components(separatedBy: " → ")
                guard parts.count == 2 else { return change.line }
                let path = "\(stepName(parts[0])) → \(stepName(parts[1]))"
                switch change.kind {
                case .added: return L("Connected \(path)")
                case .removed: return L("Disconnected \(path)")
                case .changed: return L("Changed when \(path) is taken")
                }
            }
            switch change.subject {
            case "input schema": return L("Changed what you fill in")
            case "output schema": return L("Changed the shape of what you get")
            case "output": return L("Changed what you get")
            case "model slots": return L("Changed the models it uses")
            case "secrets": return L("Changed the secrets it needs")
            case "examples": return L("Changed the examples")
            case "dependencies": return L("Changed the packages it installs")
            case "folders": return L("Changed the folders it uses")
            case "requirement notes": return L("Changed the setup notes")
            default: return change.line
            }
        }
    }

    /// `details: false` leaves `before` / `after` nil. Pretty-printing every
    /// changed step is the costly part, and summary lines never read it.
    public static func changes(from old: WorkflowDefinition, to new: WorkflowDefinition, details: Bool = true)
        -> [Change]
    {
        var out: [Change] = []
        func shown<T: Encodable>(_ value: T) -> String? { details ? pretty(value) : nil }
        let oldNodes = Dictionary(old.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newNodes = Dictionary(new.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for node in new.nodes where oldNodes[node.id] == nil {
            out.append(Change(kind: .added, subject: "node \(node.id)", fields: [], after: shown(node)))
        }
        for node in old.nodes where newNodes[node.id] == nil {
            out.append(Change(kind: .removed, subject: "node \(node.id)", fields: [], before: shown(node)))
        }
        for node in new.nodes {
            guard let before = oldNodes[node.id], before != node else { continue }
            out.append(
                Change(
                    kind: .changed, subject: "node \(node.id)", fields: changedKeys(before, node),
                    before: shown(before), after: shown(node)))
        }
        func edgeKey(_ e: WorkflowEdge) -> String { "\(e.from) → \(e.to)" }
        let oldEdges = Dictionary(old.edges.map { (edgeKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        let newEdges = Dictionary(new.edges.map { (edgeKey($0), $0) }, uniquingKeysWith: { a, _ in a })
        for edge in new.edges {
            if let before = oldEdges[edgeKey(edge)] {
                if before != edge {
                    var fields: [String] = []
                    if before.when != edge.when { fields.append("when") }
                    if before.on != edge.on { fields.append("on") }
                    out.append(Change(kind: .changed, subject: "edge \(edgeKey(edge))", fields: fields))
                }
            } else {
                out.append(Change(kind: .added, subject: "edge \(edgeKey(edge))", fields: []))
            }
        }
        for edge in old.edges where newEdges[edgeKey(edge)] == nil {
            out.append(Change(kind: .removed, subject: "edge \(edgeKey(edge))", fields: []))
        }
        func compare<T: Equatable & Encodable>(_ a: T, _ b: T, _ subject: String) {
            guard a != b else { return }
            out.append(Change(kind: .changed, subject: subject, fields: [], before: shown(a), after: shown(b)))
        }
        compare(old.inputSchema, new.inputSchema, "input schema")
        compare(old.outputSchema, new.outputSchema, "output schema")
        compare(old.output, new.output, "output")
        compare(old.modelSlots, new.modelSlots, "model slots")
        compare(old.secrets, new.secrets, "secrets")
        compare(old.examples, new.examples, "examples")
        compare(old.dependencies, new.dependencies, "dependencies")
        compare(old.folders, new.folders, "folders")
        compare(old.requirementNotes, new.requirementNotes, "requirement notes")
        return out
    }

    private static func changedKeys(_ a: WorkflowNode, _ b: WorkflowNode) -> [String] {
        guard case .object(let x) = WorkflowDraftPatcher.encode(a), case .object(let y) = WorkflowDraftPatcher.encode(b)
        else { return [] }
        var keys: [String] = []
        for key in Set(x.keys).union(y.keys).sorted() where x[key] != y[key] {
            if case .object(let xi)? = x[key], case .object(let yi)? = y[key] {
                keys += Set(xi.keys).union(yi.keys).sorted().filter { xi[$0] != yi[$0] }.map { "\(key).\($0)" }
            } else {
                keys.append(key)
            }
        }
        return keys
    }

    static func pretty<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
