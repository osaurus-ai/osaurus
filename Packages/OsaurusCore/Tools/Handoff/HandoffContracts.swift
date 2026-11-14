//
//  HandoffContracts.swift
//  osaurus
//
//  The values the Orchestrator and the hidden built-in agents it hands work
//  to agree on: the session state the Orchestrator owns, the handoff it
//  sends (the user's words verbatim plus a one-line brief), and the typed
//  result it gets back and presents as returned.
//

import Foundation

// MARK: - Session state

/// One run the session is waiting on. Written by the harness from the run
/// service, never by the model.
public struct RunRef: Codable, Equatable, Sendable, Hashable {
    public var runId: String
    public var workflow: String
    public var status: String

    public init(runId: String, workflow: String, status: String) {
        self.runId = runId
        self.workflow = workflow
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case workflow
        case status
    }
}

/// The Orchestrator's working memory for one chat: rewritten whole by the
/// `state` tool each turn (last call wins), persisted on the session record,
/// and injected beside the latest user message. `inFlight` and `stale` are
/// harness-owned: a model write never sets them.
public struct SessionState: Codable, Equatable, Sendable {
    public var goal: String?
    public var decisions: [String]
    public var facts: [String]
    public var openItems: [String]
    public var inFlight: [RunRef]
    /// True when the last turn ended without a `state` call, so this object
    /// may be out of date.
    public var stale: Bool

    /// Bounds that keep the injected block small whatever the model writes.
    public static let maxItemsPerList = 8
    public static let maxItemCharacters = 240

    public init(
        goal: String? = nil,
        decisions: [String] = [],
        facts: [String] = [],
        openItems: [String] = [],
        inFlight: [RunRef] = [],
        stale: Bool = false
    ) {
        self.goal = goal
        self.decisions = decisions
        self.facts = facts
        self.openItems = openItems
        self.inFlight = inFlight
        self.stale = stale
    }

    public static let empty = SessionState()

    public var isEmpty: Bool {
        (goal ?? "").isEmpty && decisions.isEmpty && facts.isEmpty && openItems.isEmpty && inFlight.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case goal, decisions, facts, stale
        case openItems = "open_items"
        case inFlight = "in_flight"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        goal = try c.decodeIfPresent(String.self, forKey: .goal)
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        facts = try c.decodeIfPresent([String].self, forKey: .facts) ?? []
        openItems = try c.decodeIfPresent([String].self, forKey: .openItems) ?? []
        inFlight = try c.decodeIfPresent([RunRef].self, forKey: .inFlight) ?? []
        stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
    }

    /// The model-writable fields of a `state` call. Unknown keys, and the
    /// harness-owned `in_flight` / `stale`, are ignored. Nil when the
    /// arguments are not a JSON object.
    public static func fromModelArguments(_ argumentsJSON: String) -> SessionState? {
        guard let object = JSONValue.parse(argumentsJSON)?.objectValue else { return nil }
        func list(_ key: String) -> [String] {
            let raw: [String]
            switch object[key] {
            case .array(let items): raw = items.compactMap { $0.stringValue }
            case .string(let single): raw = [single]
            default: raw = []
            }
            return
                raw
                .map { clip($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                .filter { !$0.isEmpty }
                .prefix(maxItemsPerList)
                .map { $0 }
        }
        let goal = object["goal"]?.stringValue
            .map { clip($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { $0.isEmpty ? nil : $0 }
        return SessionState(
            goal: goal,
            decisions: list("decisions"),
            facts: list("facts"),
            openItems: list("open_items")
        )
    }

    private static func clip(_ text: String) -> String {
        text.count > maxItemCharacters ? String(text.prefix(maxItemCharacters)) + "…" : text
    }

    /// The block injected beside the user turn. Byte-stable for equal state.
    public func rendered() -> String {
        var lines: [String] = ["[Session state\(stale ? " (stale: not updated last turn)" : "")]"]
        lines.append("goal: \(goal ?? "none")")
        func section(_ name: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append("\(name):")
            lines += items.map { "- \($0)" }
        }
        section("decisions", decisions)
        section("facts", facts)
        section("open_items", openItems)
        section("in_flight", inFlight.map { "\($0.workflow) (\($0.status), run \($0.runId))" })
        return lines.joined(separator: "\n")
    }

    /// JSON for the session record.
    public func encoded() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decoded(_ json: String?) -> SessionState? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionState.self, from: data)
    }
}

// MARK: - Handoff

/// Where a handoff came from.
public struct CallerContext: Sendable, Equatable {
    public var sessionId: String?
    public var agentId: UUID
    public var source: String

    public init(sessionId: String?, agentId: UUID, source: String = "chat") {
        self.sessionId = sessionId
        self.agentId = agentId
        self.source = source
    }

    /// The caller bound on the current task.
    public static func current() -> CallerContext {
        CallerContext(
            sessionId: ChatExecutionContext.currentSessionId,
            agentId: ChatExecutionContext.currentAgentId ?? Agent.defaultId
        )
    }
}

/// What the Orchestrator sends a hidden agent. `userMessage` is the turn's
/// exact user text: the host overwrites whatever the model passed.
public struct Handoff: Sendable, Equatable {
    public var userMessage: String
    public var brief: String
    public var state: SessionState
    public var caller: CallerContext

    public init(userMessage: String, brief: String, state: SessionState, caller: CallerContext) {
        self.userMessage = userMessage
        self.brief = brief
        self.state = state
        self.caller = caller
    }

    /// Build from tool arguments. The verbatim text comes from the turn
    /// (`ChatExecutionContext.currentUserRequest`); the model's
    /// `user_message` is used only where no turn text is bound (HTTP, evals
    /// calling the tool directly).
    public static func fromToolArguments(
        _ argumentsJSON: String,
        turnUserText: String?,
        state: SessionState,
        caller: CallerContext
    ) -> Handoff? {
        let object = JSONValue.parse(argumentsJSON)?.objectValue ?? [:]
        let modelMessage = object["user_message"]?.stringValue ?? ""
        let turnText = turnUserText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = turnText.isEmpty ? modelMessage.trimmingCharacters(in: .whitespacesAndNewlines) : turnText
        guard !message.isEmpty else { return nil }
        let brief = (object["brief"]?.stringValue ?? "")
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Handoff(userMessage: message, brief: brief, state: state, caller: caller)
    }
}

// MARK: - Result

/// What a handoff returns. The Orchestrator presents it as returned.
public enum HandoffResult: Equatable, Sendable {
    /// An answer, no change made.
    case answer(String)
    /// A change landed; the text says what.
    case applied(String)
    /// Files the work produced (already shared to the chat).
    case files([SharedArtifact], summary: String)
    /// The request needs a step only the user can do (sign-in, key, setup).
    case needsSetup(String)
    /// A run is waiting on the user; the turn is parked.
    case awaitingUser(RunRef, question: String)
    /// Not done: the user declined, or the target refused.
    case declined(String)
    /// The handoff could not decide alone: present `question` through
    /// `clarify` with `options` (at most two).
    case needsChoice(question: String, options: [String])

    public var kind: String {
        switch self {
        case .answer: return "answer"
        case .applied: return "applied"
        case .files: return "files"
        case .needsSetup: return "needs_setup"
        case .awaitingUser: return "awaiting_user"
        case .declined: return "declined"
        case .needsChoice: return "needs_choice"
        }
    }

    /// The prose the Orchestrator presents.
    public var text: String {
        switch self {
        case .answer(let text), .applied(let text), .needsSetup(let text), .declined(let text):
            return text
        case .files(_, let summary): return summary
        case .awaitingUser(_, let question): return question
        case .needsChoice(let question, _): return question
        }
    }

    /// The success envelope a handoff tool returns.
    public func envelope(tool: String) -> String {
        ToolEnvelope.success(tool: tool, result: payload)
    }

    /// The envelope's `result` object. `present` tells the Orchestrator what
    /// to do with it in one line.
    public var payload: [String: Any] {
        var result: [String: Any] = ["handoff_result": kind, "text": text]
        switch self {
        case .files(let artifacts, _):
            result["files"] = artifacts.map { $0.filename }
        case .awaitingUser(let run, _):
            result["run"] = ["run_id": run.runId, "workflow": run.workflow, "status": run.status]
        case .needsChoice(_, let options):
            result["options"] = options
        default:
            break
        }
        result["present"] = presentInstruction
        return result
    }

    private var presentInstruction: String {
        switch self {
        case .answer, .applied, .files, .needsSetup:
            return "Give the user `text` as written, then call state."
        case .declined:
            return "Tell the user `text` as written; nothing was changed. Then call state."
        case .awaitingUser:
            return "Ask the user `text` as written; their reply resumes the run. Then call state."
        case .needsChoice:
            return "Call clarify with `text` as the question and `options` as the options."
        }
    }

    /// Parse a handoff envelope back (tests, the presenting turn).
    public static func parse(envelope: String) -> HandoffResult? {
        guard let payload = ToolEnvelope.successPayload(envelope) as? [String: Any],
            let kind = payload["handoff_result"] as? String
        else { return nil }
        let text = payload["text"] as? String ?? ""
        switch kind {
        case "answer": return .answer(text)
        case "applied": return .applied(text)
        case "files": return .files([], summary: text)
        case "needs_setup": return .needsSetup(text)
        case "declined": return .declined(text)
        case "needs_choice":
            return .needsChoice(question: text, options: payload["options"] as? [String] ?? [])
        case "awaiting_user":
            let run = payload["run"] as? [String: Any] ?? [:]
            return .awaitingUser(
                RunRef(
                    runId: run["run_id"] as? String ?? "",
                    workflow: run["workflow"] as? String ?? "",
                    status: run["status"] as? String ?? "awaiting_user"),
                question: text)
        default: return nil
        }
    }
}
