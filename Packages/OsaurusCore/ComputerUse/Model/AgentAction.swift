//
//  AgentAction.swift
//  OsaurusCore — Computer Use
//
//  The single model-facing envelope. Inside the Computer Use loop the model
//  only ever fills ONE `agent_action` per step — never the 18 raw driver
//  tools. The harness owns every deterministic decision (which element, which
//  tier, whether to confirm); the model only proposes the next intent.
//
//  Schema-constrained decoding (Principle 3) without a constraint-grammar
//  sampler: one `agent_action` tool + forced `tool_choice` + a strict
//  JSON-schema `parameters` (constrained verb enum) + post-generation
//  coercion/validation via `SchemaValidator` + a bounded re-ask (fed back as
//  a `note`) when the shape is wrong. See `ComputerUseLoop`.
//

import Foundation

// MARK: - Verb

/// The constrained verb vocabulary. The raw values are the schema `enum`
/// the model must pick from; nothing outside this set decodes.
public enum AgentVerb: String, Sendable, Codable, CaseIterable {
    /// Re-perceive the current app (no mutation). The loop perceives every
    /// step anyway; `observe` is the explicit "I just need a fresh look".
    case observe
    /// Wait a short, bounded interval for async UI (a spinner, a load) to
    /// settle, then re-perceive. `seconds` (capped) controls how long.
    case wait
    /// Server-side element query (filter by text/role) — a focused capture.
    case find
    /// Click an element (or its resolved center).
    case click
    /// Double-click an element (or its resolved center).
    case doubleClick = "double_click"
    /// Right-click an element to open its context menu.
    case rightClick = "right_click"
    /// Drag from one element (`target`) to another (`to`).
    case drag
    /// Type text, optionally into a resolved field.
    case type
    /// Set an editable element's value wholesale.
    case setValue = "set_value"
    /// Clear an editable field.
    case clear
    /// Press a key (optionally with modifiers) in the app context.
    case pressKey = "press_key"
    /// Scroll the focused window / a resolved element.
    case scroll
    /// Launch or switch to an app.
    case open
    /// Terminal: the goal is achieved. `reason` summarizes the outcome.
    case done
    /// Terminal: the goal cannot be achieved. `reason` explains why.
    case giveUp = "give_up"

    /// Verb-only baseline effect. PR1's gate is hardwired against this; PR2's
    /// `EffectClassifier` refines it upward using resolved role + app context
    /// (e.g. a `click` on a "Send" button becomes `consequential`). It can
    /// only ever escalate, never lower, so this is the floor.
    public var baselineEffect: EffectClass {
        switch self {
        case .observe, .wait, .find, .done, .giveUp:
            return .read
        case .click, .doubleClick, .rightClick, .scroll, .open:
            return .navigate
        case .type, .setValue, .clear, .pressKey, .drag:
            return .edit
        }
    }

    /// Whether the verb terminates the loop.
    public var isTerminal: Bool { self == .done || self == .giveUp }
}

// MARK: - Target

/// How the model points at an element. The model never sees raw `s7-12`
/// ids — it addresses a compact `mark` from the `AgentView`, or falls back
/// to a natural-language `describe` the `TargetResolver` matches. At least
/// one is required for element-addressed verbs.
public struct AgentTarget: Sendable, Equatable {
    /// 1-based index into the current `AgentView.items`.
    public let mark: Int?
    /// Natural-language fallback (role + label), matched when `mark` is
    /// absent or has gone stale.
    public let describe: String?

    public init(mark: Int? = nil, describe: String? = nil) {
        self.mark = mark
        self.describe = describe
    }

    public var isEmpty: Bool { mark == nil && (describe?.isEmpty ?? true) }
}

// MARK: - AgentAction

/// One decoded step. Fields beyond `verb` are verb-specific and validated
/// by `decode`.
public struct AgentAction: Sendable, Equatable {
    public let verb: AgentVerb
    public let target: AgentTarget?
    /// `drag` only: the destination element (resolved like `target`).
    public let to: AgentTarget?
    /// `wait` only: how long to pause before re-perceiving, in seconds. The
    /// loop caps this so a model can't stall the run.
    public let seconds: Int?
    /// Text payload for `type` / `set_value`.
    public let text: String?
    /// `type` only: replace the field's contents (default) vs append.
    public let replace: Bool?
    /// `press_key` only: the key name (e.g. `return`, `escape`, `a`).
    public let key: String?
    /// `press_key` only: modifier names (`cmd`, `shift`, …).
    public let modifiers: [String]
    /// `scroll` only.
    public let direction: CUScrollDirection?
    /// `scroll` only: wheel clicks.
    public let amount: Int?
    /// `open` only: app name / bundle id / path.
    public let app: String?
    /// `find` only: substring to match.
    public let query: String?
    /// `find` only: role filter.
    public let roles: [String]
    /// One-line rationale/narration shown in the activity feed.
    public let note: String?
    /// `done` / `give_up` only: the outcome summary.
    public let reason: String?

    public init(
        verb: AgentVerb,
        target: AgentTarget? = nil,
        to: AgentTarget? = nil,
        seconds: Int? = nil,
        text: String? = nil,
        replace: Bool? = nil,
        key: String? = nil,
        modifiers: [String] = [],
        direction: CUScrollDirection? = nil,
        amount: Int? = nil,
        app: String? = nil,
        query: String? = nil,
        roles: [String] = [],
        note: String? = nil,
        reason: String? = nil
    ) {
        self.verb = verb
        self.target = target
        self.to = to
        self.seconds = seconds
        self.text = text
        self.replace = replace
        self.key = key
        self.modifiers = modifiers
        self.direction = direction
        self.amount = amount
        self.app = app
        self.query = query
        self.roles = roles
        self.note = note
        self.reason = reason
    }

    /// The verb-only baseline effect (PR1 gate floor).
    public var baselineEffect: EffectClass { verb.baselineEffect }

    /// A short human label for the feed ("Click mark 3", "Type \"hello\"").
    public var feedLabel: String {
        switch verb {
        case .observe: return "Observe"
        case .wait: return "Wait" + (seconds.map { " \($0)s" } ?? "")
        case .find: return "Find " + (query.map { "\"\($0)\"" } ?? "elements")
        case .click: return "Click " + targetLabel
        case .doubleClick: return "Double-click " + targetLabel
        case .rightClick: return "Right-click " + targetLabel
        case .drag: return "Drag " + targetLabel + " to " + destinationLabel
        case .type: return "Type " + quoted(text) + (target != nil ? " into \(targetLabel)" : "")
        case .setValue: return "Set " + targetLabel + " = " + quoted(text)
        case .clear: return "Clear " + targetLabel
        case .pressKey:
            let combo = (modifiers + [key].compactMap { $0 }).joined(separator: "+")
            return "Press " + (combo.isEmpty ? "key" : combo)
        case .scroll: return "Scroll " + (direction?.rawValue ?? "down")
        case .open: return "Open " + (app ?? "app")
        case .done: return "Done"
        case .giveUp: return "Give up"
        }
    }

    /// The full text payload a confirm card can show expandably (the feed label
    /// truncates it at 40 chars). `nil` for verbs that carry no typed payload.
    public var typedTextForPreview: String? {
        switch verb {
        case .type, .setValue:
            guard let text, !text.isEmpty else { return nil }
            return text
        default:
            return nil
        }
    }

    private var targetLabel: String { Self.label(for: target) }
    private var destinationLabel: String { Self.label(for: to) }

    private static func label(for target: AgentTarget?) -> String {
        guard let target else { return "target" }
        if let mark = target.mark { return "mark \(mark)" }
        if let d = target.describe, !d.isEmpty { return "\"\(d)\"" }
        return "target"
    }

    private func quoted(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "\"\"" }
        let clipped = s.count > 40 ? String(s.prefix(40)) + "…" : s
        return "\"\(clipped)\""
    }

    /// Serialize this action into the `agent_action` arguments JSON the model
    /// would emit (only the fields the verb uses). Round-trips with `decode`,
    /// so scripted-model providers in tests/evals can drive the loop with real
    /// actions instead of brittle JSON string literals.
    public func argumentsJSON() -> String {
        var obj: [String: Any] = ["verb": verb.rawValue]
        if let target {
            var t: [String: Any] = [:]
            if let mark = target.mark { t["mark"] = mark }
            if let describe = target.describe { t["describe"] = describe }
            if !t.isEmpty { obj["target"] = t }
        }
        if let to {
            var t: [String: Any] = [:]
            if let mark = to.mark { t["mark"] = mark }
            if let describe = to.describe { t["describe"] = describe }
            if !t.isEmpty { obj["to"] = t }
        }
        if let seconds { obj["seconds"] = seconds }
        if let text { obj["text"] = text }
        if let replace { obj["replace"] = replace }
        if let key { obj["key"] = key }
        if !modifiers.isEmpty { obj["modifiers"] = modifiers }
        if let direction { obj["direction"] = direction.rawValue }
        if let amount { obj["amount"] = amount }
        if let app { obj["app"] = app }
        if let query { obj["query"] = query }
        if !roles.isEmpty { obj["roles"] = roles }
        if let note { obj["note"] = note }
        if let reason { obj["reason"] = reason }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{\"verb\":\"\(verb.rawValue)\"}"
        }
        return json
    }
}

// MARK: - Decode result

/// Outcome of decoding a model-emitted `agent_action` call.
public enum AgentActionDecode: Sendable {
    case action(AgentAction)
    /// The shape was wrong. `reason` is fed back to the model as a `note`
    /// for a bounded re-ask (see `ComputerUseLoop`).
    case invalid(reason: String)
}

// MARK: - Schema + decode

extension AgentAction {
    /// The tool name the model calls inside the loop.
    public static let toolName = "agent_action"

    /// Strict JSON schema for the single envelope. `additionalProperties:
    /// false` + a constrained `verb` enum is the closest we get to grammar
    /// sampling without a constraint sampler in vmlx.
    public static let schema: JSONValue = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "verb": .object([
                "type": .string("string"),
                "enum": .array(AgentVerb.allCases.map { .string($0.rawValue) }),
                "description": .string(
                    "The single next action. Read/look: observe, wait, find. "
                        + "Move: click, double_click, right_click, scroll, drag, open. "
                        + "Edit: type, set_value, clear, press_key. Finish: done (success) or give_up."
                ),
            ]),
            "target": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "mark": .object([
                        "type": .string("integer"),
                        "description": .string("The number shown next to the element in the current view."),
                    ]),
                    "describe": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Natural-language fallback (role + label) when you don't have a mark, "
                                + "e.g. \"the Send button\"."
                        ),
                    ]),
                ]),
                "description": .string(
                    "Which element to act on (for click/double_click/right_click/type/set_value/clear, "
                        + "and the start element for drag)."
                ),
            ]),
            "to": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object([
                    "mark": .object([
                        "type": .string("integer"),
                        "description": .string("The number shown next to the destination element."),
                    ]),
                    "describe": .object([
                        "type": .string("string"),
                        "description": .string("Natural-language fallback for the destination element."),
                    ]),
                ]),
                "description": .string("Drag destination element (for drag)."),
            ]),
            "seconds": .object([
                "type": .string("integer"),
                "description": .string("How many seconds to wait for async UI to settle (for wait)."),
            ]),
            "text": .object([
                "type": .string("string"),
                "description": .string("Text to type or set (for type/set_value)."),
            ]),
            "replace": .object([
                "type": .string("boolean"),
                "description": .string("For type: replace the field contents (default true) vs append."),
            ]),
            "key": .object([
                "type": .string("string"),
                "description": .string("Key name for press_key, e.g. return, escape, tab, a."),
            ]),
            "modifiers": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Modifier keys for press_key: cmd, shift, option, control."),
            ]),
            "direction": .object([
                "type": .string("string"),
                "enum": .array(CUScrollDirection.allCases.map { .string($0.rawValue) }),
                "description": .string("Scroll direction (for scroll)."),
            ]),
            "amount": .object([
                "type": .string("integer"),
                "description": .string("Scroll amount in wheel clicks (for scroll, default 3)."),
            ]),
            "app": .object([
                "type": .string("string"),
                "description": .string("App name, bundle id, or path (for open)."),
            ]),
            "query": .object([
                "type": .string("string"),
                "description": .string("Substring to match (for find)."),
            ]),
            "roles": .object([
                "type": .string("array"),
                "items": .object(["type": .string("string")]),
                "description": .string("Role filter like button, textfield (for find)."),
            ]),
            "note": .object([
                "type": .string("string"),
                "description": .string("One short sentence explaining why you're taking this step."),
            ]),
            "reason": .object([
                "type": .string("string"),
                "description": .string("Outcome summary (required for done/give_up)."),
            ]),
        ]),
        "required": .array([.string("verb")]),
    ])

    /// The OpenAI-compatible tool spec for the request `tools[]`.
    /// Internal: `Tool` is a module-internal type.
    static var toolSpec: Tool {
        Tool(
            type: "function",
            function: ToolFunction(
                name: toolName,
                description:
                    "Propose the single next computer-use action. Pick exactly one verb and fill only the "
                    + "fields that verb needs. Address elements by the `mark` number shown in the view.",
                parameters: schema
            )
        )
    }

    /// The forced tool choice that pins the model to `agent_action`.
    /// Internal: `ToolChoiceOption` is a module-internal type.
    static var forcedToolChoice: ToolChoiceOption {
        .function(.init(type: "function", function: .init(name: toolName)))
    }

    /// Decode + coerce + validate a model-emitted arguments JSON string.
    /// Returns `.invalid(reason:)` with a model-readable explanation on any
    /// shape problem so the loop can re-ask.
    public static func decode(argumentsJSON: String) -> AgentActionDecode {
        guard let data = argumentsJSON.data(using: .utf8),
            let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return .invalid(
                reason: "Your action was not valid JSON. Reply with a single agent_action object."
            )
        }

        // The chat engine pre-validates tool arguments and, on a schema miss,
        // replaces the model's JSON with an `_error` envelope before the loop
        // ever sees it. Surface that real message (e.g. "Property 'mark' must be
        // an integer") so the re-ask tells the model what to fix — otherwise we
        // re-validate the envelope and report the misleading "Missing required
        // property: verb".
        if let errorKind = raw["_error"] as? String, errorKind == "invalid_tool_arguments" {
            let message =
                (raw["_message"] as? String)
                ?? "Your action did not match the required shape. Check the field names and types."
            if let field = raw["_field"] as? String, !field.isEmpty {
                return .invalid(reason: shapeHint(for: field, base: "\(message) (problem with `\(field)`)"))
            }
            return .invalid(reason: message)
        }

        // Reuse the tool-arg coercion + validation the rest of the app uses, so
        // string-encoded ints/arrays/bools from quantized models pass.
        let coerced = SchemaValidator.coerceArguments(raw, against: schema)
        let validation = SchemaValidator.validate(arguments: coerced, against: schema)
        guard validation.isValid else {
            let base =
                validation.errorMessage
                ?? "Your action did not match the required shape. Check the field names and types."
            if let field = validation.field, !field.isEmpty {
                return .invalid(reason: shapeHint(for: field, base: base))
            }
            return .invalid(reason: base)
        }
        guard let dict = coerced as? [String: Any] else {
            return .invalid(reason: "Your action must be a JSON object.")
        }

        guard let verbRaw = dict["verb"] as? String,
            let verb = AgentVerb(rawValue: verbRaw.lowercased())
        else {
            let allowed = AgentVerb.allCases.map { $0.rawValue }.joined(separator: ", ")
            return .invalid(reason: "`verb` must be one of: \(allowed).")
        }

        let target = parseTarget(dict["target"])
        let to = parseTarget(dict["to"])
        let seconds = ArgumentCoercion.int(dict["seconds"])
        let text = (dict["text"] as? String)
        let replace = ArgumentCoercion.bool(dict["replace"])
        let key = (dict["key"] as? String)
        let modifiers = ArgumentCoercion.stringArray(dict["modifiers"]) ?? []
        let direction = (dict["direction"] as? String).flatMap {
            CUScrollDirection(rawValue: $0.lowercased())
        }
        let amount = ArgumentCoercion.int(dict["amount"])
        let app = (dict["app"] as? String)
        let query = (dict["query"] as? String)
        let roles = ArgumentCoercion.stringArray(dict["roles"]) ?? []
        let note = (dict["note"] as? String)
        let reason = (dict["reason"] as? String)

        let action = AgentAction(
            verb: verb,
            target: target,
            to: to,
            seconds: seconds,
            text: text,
            replace: replace,
            key: key,
            modifiers: modifiers,
            direction: direction,
            amount: amount,
            app: app,
            query: query,
            roles: roles,
            note: note,
            reason: reason
        )

        if let problem = action.semanticProblem() {
            return .invalid(reason: problem)
        }
        return .action(action)
    }

    /// Append a concrete, worked correction to a schema-rejection reason for
    /// the handful of fields models most often mis-shape. Pure feedback — it
    /// only changes the re-ask text the model reads, never the accepted
    /// values (a malformed action still fails). Helps any model self-correct
    /// instead of repeating the same wrong shape until the re-ask budget runs
    /// out (e.g. a 4B that emits `"mark": true`).
    private static func shapeHint(for field: String, base: String) -> String {
        switch field {
        case "mark":
            return base
                + " `mark` is the integer in the [N] brackets next to the element"
                + " — e.g. \"target\": {\"mark\": 1}. Not true/false, a label, or a"
                + " quoted string. If you don't have a number, drop `mark` and use"
                + " \"describe\": \"the <role> labelled <text>\" instead."
        case "target", "to":
            return base
                + " `\(field)` is an object: {\"mark\": <number from [N]>} or"
                + " {\"describe\": \"the <role> labelled <text>\"}."
        default:
            return base
        }
    }

    private static func parseTarget(_ value: Any?) -> AgentTarget? {
        guard let dict = value as? [String: Any] else { return nil }
        let mark = ArgumentCoercion.int(dict["mark"])
        let describe = (dict["describe"] as? String).flatMap {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        }
        if mark == nil && describe == nil { return nil }
        return AgentTarget(mark: mark, describe: describe)
    }

    /// Verb-specific required-field check beyond the JSON schema (which can't
    /// express "click requires a target"). Returns a model-readable reason
    /// when something required for the chosen verb is missing.
    func semanticProblem() -> String? {
        switch verb {
        case .observe, .wait:
            return nil
        case .find:
            if (query?.isEmpty ?? true) && roles.isEmpty {
                return "find needs a `query` substring and/or `roles` filter."
            }
            return nil
        case .click, .clear, .doubleClick, .rightClick:
            if target?.isEmpty ?? true {
                return "\(verb.rawValue) needs a `target` (a `mark` number or a `describe`)."
            }
            return nil
        case .drag:
            if target?.isEmpty ?? true {
                return "drag needs a `target` (the start element)."
            }
            if to?.isEmpty ?? true {
                return "drag needs a `to` (the destination element)."
            }
            return nil
        case .type, .setValue:
            if text == nil {
                return "\(verb.rawValue) needs `text`."
            }
            if verb == .setValue, target?.isEmpty ?? true {
                return "set_value needs a `target` field."
            }
            return nil
        case .pressKey:
            if key?.isEmpty ?? true {
                return "press_key needs a `key`."
            }
            return nil
        case .scroll:
            if direction == nil {
                return "scroll needs a `direction` (up, down, left, right)."
            }
            return nil
        case .open:
            if app?.isEmpty ?? true {
                return "open needs an `app` name."
            }
            return nil
        case .done, .giveUp:
            if (reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true {
                return "\(verb.rawValue) needs a `reason` summarizing the outcome."
            }
            return nil
        }
    }
}
