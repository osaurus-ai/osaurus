//
//  AgentAction.swift
//  OsaurusCore — Computer Use
//
//  The single model-facing envelope. Inside the Computer Use loop the model
//  fills ONE `agent_action` call per step — never the raw driver tools. A
//  `batch` call carries a short, ordered list of acting steps that the loop
//  gates one by one. The harness owns every deterministic decision (which element, which
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
    /// Move the pointer over an element or point without clicking (tooltips,
    /// hover menus, reveal-on-hover controls).
    case hover
    /// Pick an `option` from a popup button, menu button, or combo box.
    case select
    /// Look closer: a full-resolution crop of a `region` of the latest
    /// screenshot. Read-only.
    case zoom
    /// Capture the window as a marked screenshot. Read-only.
    case screenshot
    /// Run a short list of acting steps in order (`actions`), each gated.
    case batch
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
        case .observe, .wait, .find, .done, .giveUp, .zoom, .screenshot, .batch:
            return .read
        case .click, .doubleClick, .rightClick, .scroll, .open, .hover, .select:
            return .navigate
        case .type, .setValue, .clear, .pressKey, .drag:
            return .edit
        }
    }

    /// Whether the verb terminates the loop.
    public var isTerminal: Bool { self == .done || self == .giveUp }

    /// Verbs a `batch` may carry: acting steps that need no fresh look in
    /// between. Reads, app switches, and terminal verbs stay single calls.
    public var isBatchable: Bool {
        switch self {
        case .click, .doubleClick, .rightClick, .drag, .type, .setValue, .clear, .pressKey, .scroll,
            .hover, .select:
            return true
        case .observe, .wait, .find, .open, .done, .giveUp, .zoom, .screenshot, .batch:
            return false
        }
    }
}

// MARK: - Screenshot geometry

/// A point in the pixel space of the latest screenshot the model was shown
/// (origin top-left).
public struct AgentPoint: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rectangle in the pixel space of the latest screenshot.
public struct AgentRegion: Sendable, Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// MARK: - Target

/// How the model points at an element. The model never sees raw `s7-12`
/// ids — it addresses a compact `mark` from the `AgentView`, falls back to a
/// natural-language `describe` the `TargetResolver` matches, or gives a
/// `point` in the latest screenshot. At least one is required for
/// element-addressed verbs.
public struct AgentTarget: Sendable, Equatable {
    /// 1-based index into the current `AgentView.items`.
    public let mark: Int?
    /// Natural-language fallback (role + label), matched when `mark` is
    /// absent or has gone stale.
    public let describe: String?
    /// Pixel coordinates in the latest screenshot. When set it decides the
    /// target; `mark` and `describe` are not used to locate it.
    public let point: AgentPoint?

    public init(mark: Int? = nil, describe: String? = nil, point: AgentPoint? = nil) {
        self.mark = mark
        self.describe = describe
        self.point = point
    }

    public var isEmpty: Bool { mark == nil && (describe?.isEmpty ?? true) && point == nil }
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
    /// `press_key` only: how many times to press it (the loop caps this).
    public let repeatCount: Int?
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
    /// `select` only: the option's visible title.
    public let option: String?
    /// `zoom` only: the area of the latest screenshot to look at closely.
    public let region: AgentRegion?
    /// `batch` only: the steps to run, in order.
    public let actions: [AgentAction]
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
        repeatCount: Int? = nil,
        direction: CUScrollDirection? = nil,
        amount: Int? = nil,
        app: String? = nil,
        query: String? = nil,
        roles: [String] = [],
        option: String? = nil,
        region: AgentRegion? = nil,
        actions: [AgentAction] = [],
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
        self.repeatCount = repeatCount
        self.direction = direction
        self.amount = amount
        self.app = app
        self.query = query
        self.roles = roles
        self.option = option
        self.region = region
        self.actions = actions
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
            let times = (repeatCount ?? 1) > 1 ? " ×\(repeatCount!)" : ""
            return "Press " + (combo.isEmpty ? "key" : combo) + times
        case .scroll: return "Scroll " + (direction?.rawValue ?? "down")
        case .hover: return "Hover " + targetLabel
        case .select: return "Select " + quoted(option) + " in " + targetLabel
        case .zoom: return "Zoom in"
        case .screenshot: return "Take a screenshot"
        case .batch: return "Run \(actions.count) steps: " + actions.map(\.feedLabel).joined(separator: ", ")
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
        if let point = target.point { return "point (\(Int(point.x)), \(Int(point.y)))" }
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
        guard let data = try? JSONSerialization.data(withJSONObject: argumentsObject()),
            let json = String(data: data, encoding: .utf8)
        else {
            return "{\"verb\":\"\(verb.rawValue)\"}"
        }
        return json
    }

    private func argumentsObject() -> [String: Any] {
        func targetObject(_ target: AgentTarget?) -> [String: Any]? {
            guard let target else { return nil }
            var t: [String: Any] = [:]
            if let mark = target.mark { t["mark"] = mark }
            if let describe = target.describe { t["describe"] = describe }
            if let point = target.point { t["point"] = ["x": point.x, "y": point.y] }
            return t.isEmpty ? nil : t
        }
        var obj: [String: Any] = ["verb": verb.rawValue]
        if let t = targetObject(target) { obj["target"] = t }
        if let t = targetObject(to) { obj["to"] = t }
        if let seconds { obj["seconds"] = seconds }
        if let text { obj["text"] = text }
        if let replace { obj["replace"] = replace }
        if let key { obj["key"] = key }
        if !modifiers.isEmpty { obj["modifiers"] = modifiers }
        if let repeatCount { obj["repeat"] = repeatCount }
        if let direction { obj["direction"] = direction.rawValue }
        if let amount { obj["amount"] = amount }
        if let app { obj["app"] = app }
        if let query { obj["query"] = query }
        if !roles.isEmpty { obj["roles"] = roles }
        if let option { obj["option"] = option }
        if let region {
            obj["region"] = ["x": region.x, "y": region.y, "width": region.width, "height": region.height]
        }
        if !actions.isEmpty { obj["actions"] = actions.map { $0.argumentsObject() } }
        if let note { obj["note"] = note }
        if let reason { obj["reason"] = reason }
        return obj
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

    /// Most steps one `batch` may carry. Longer plans go stale: every step
    /// after the first acts on a view the model saw before the earlier ones
    /// changed it.
    public static let maxBatchActions = 8

    /// Most presses one `press_key` may repeat.
    public static let maxKeyRepeat = 20

    private static func targetSchema(
        _ description: String, markDescription: String, describeDescription: String, pointDescription: String
    ) -> JSONValue {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "mark": .object([
                    "type": .string("integer"),
                    "description": .string(markDescription),
                ]),
                "describe": .object([
                    "type": .string("string"),
                    "description": .string(describeDescription),
                ]),
                "point": pointSchema(pointDescription),
            ]),
            "description": .string(description),
        ])
    }

    /// A point is `{x, y}` or `[x, y]`; both are part of the contract (the
    /// array is how Qwen-VL grounding and Anthropic's `coordinate` write it).
    static func pointSchema(_ description: String) -> JSONValue {
        .object([
            "anyOf": .array([
                .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "x": .object(["type": .string("number")]),
                        "y": .object(["type": .string("number")]),
                    ]),
                    "required": .array([.string("x"), .string("y")]),
                ]),
                .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("number")]),
                    "minItems": .number(2),
                    "maxItems": .number(2),
                ]),
            ]),
            "description": .string(description),
        ])
    }

    /// How `target.point` is described under `pointing`.
    static func pointDescription(_ pointing: PointingSurface) -> String {
        switch pointing {
        case .frame(.pixels):
            return "Pixel coordinates in the latest screenshot (origin top-left). Use when the element has no "
                + "mark; when set, it decides the target."
        case .frame(let frame):
            return "Position in the latest screenshot as \(frame.phrase) (origin top-left). Use when the "
                + "element has no mark; when set, it decides the target."
        case .marksOnly:
            return "Not available for this model; address the element by `mark` or `describe`."
        case .unstated:
            return "Position of the element in the latest screenshot (origin top-left)."
        }
    }

    /// How a zoom `region` is described under `pointing`.
    static func regionDescription(_ pointing: PointingSurface) -> String {
        switch pointing {
        case .frame(.pixels):
            return "For zoom: the area of the latest screenshot to see at full resolution, in its pixels."
        case .frame(let frame):
            return "For zoom: the area of the latest screenshot to see at full resolution, as \(frame.phrase)."
        case .marksOnly:
            return "Not available for this model."
        case .unstated:
            return "For zoom: the area of the latest screenshot to see at full resolution."
        }
    }

    /// The fields of one action, shared by the top level and each `batch` step.
    private static func actionProperties(pointing: PointingSurface) -> [String: JSONValue] { [
        "verb": .object([
            "type": .string("string"),
            "enum": .array(AgentVerb.allCases.map { .string($0.rawValue) }),
            "description": .string(
                "The next action. Look: observe, wait, find, screenshot, zoom. "
                    + "Move: click, double_click, right_click, hover, scroll, drag, select, open. "
                    + "Edit: type, set_value, clear, press_key. Several acting steps at once: batch. "
                    + "Finish: done (success) or give_up."
            ),
        ]),
        "target": targetSchema(
            "Which element to act on (for click/double_click/right_click/hover/select/type/set_value/clear, "
                + "and the start element for drag).",
            markDescription: "The number shown next to the element in the current view.",
            describeDescription:
                "Natural-language fallback (role + label) when you don't have a mark, e.g. \"the Send button\".",
            pointDescription: pointDescription(pointing)
        ),
        "to": targetSchema(
            "Drag destination element (for drag).",
            markDescription: "The number shown next to the destination element.",
            describeDescription: "Natural-language fallback for the destination element.",
            pointDescription: pointDescription(pointing)
        ),
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
            "description": .string("Key name for press_key, e.g. return, escape, tab, down, a."),
        ]),
        "modifiers": .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string("Modifier keys for press_key: cmd, shift, option, control."),
        ]),
        "repeat": .object([
            "type": .string("integer"),
            "description": .string("For press_key: how many times to press it (default 1, at most \(maxKeyRepeat))."),
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
            "description": .string(
                "For open: an app name or bundle id to launch or switch to, or an absolute or ~ folder path "
                    + "(e.g. ~/Downloads) to open that folder in a new front Finder window."
            ),
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
        "option": .object([
            "type": .string("string"),
            "description": .string("For select: the visible title of the option to pick."),
        ]),
        "region": .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "x": .object(["type": .string("number")]),
                "y": .object(["type": .string("number")]),
                "width": .object(["type": .string("number")]),
                "height": .object(["type": .string("number")]),
            ]),
            "required": .array([.string("x"), .string("y"), .string("width"), .string("height")]),
            "description": .string(regionDescription(pointing)),
        ]),
        "note": .object([
            "type": .string("string"),
            "description": .string("One short sentence explaining why you're taking this step."),
        ]),
        "reason": .object([
            "type": .string("string"),
            "description": .string("Outcome summary (required for done/give_up)."),
        ]),
    ] }

    /// Strict JSON schema for the envelope. `additionalProperties: false` + a
    /// constrained `verb` enum is the closest we get to grammar sampling
    /// without a constraint sampler in vmlx.
    public static let schema: JSONValue = schema(pointing: .frame(.pixels))

    static func schema(pointing: PointingSurface) -> JSONValue {
        let actionProperties = actionProperties(pointing: pointing)
        var properties = actionProperties
        properties["actions"] = .object([
            "type": .string("array"),
            "items": .object([
                "type": .string("object"),
                "additionalProperties": .bool(false),
                "properties": .object(actionProperties),
                "required": .array([.string("verb")]),
            ]),
            "description": .string(
                "For batch: up to \(maxBatchActions) acting steps (click, double_click, right_click, hover, "
                    + "select, drag, type, set_value, clear, press_key, scroll) run in order. Marks refer to "
                    + "the current view. The batch stops at the first step that fails, is declined, or needs "
                    + "approval; you then get one fresh view."
            ),
        ])
        return .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object(properties),
            "required": .array([.string("verb")]),
        ])
    }

    /// The OpenAI-compatible tool spec for the request `tools[]`.
    /// Internal: `Tool` is a module-internal type.
    static var toolSpec: Tool { toolSpec(pointing: .frame(.pixels)) }

    static func toolSpec(pointing: PointingSurface) -> Tool {
        let addressing =
            pointing == .marksOnly
            ? "Address elements by the `mark` number shown in the view, or by `describe`."
            : "Address elements by the `mark` number shown in the view, or by a `point` in the latest screenshot."
        return Tool(
            type: "function",
            function: ToolFunction(
                name: toolName,
                description:
                    "Propose the next computer-use action. Pick one verb and fill only the fields that verb "
                    + "needs. " + addressing,
                parameters: pointing == .frame(.pixels) ? schema : schema(pointing: pointing)
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
        return decodeObject(dict, inBatch: false)
    }

    private static func decodeObject(_ dict: [String: Any], inBatch: Bool) -> AgentActionDecode {
        guard let verbRaw = dict["verb"] as? String,
            let verb = AgentVerb(rawValue: verbRaw.lowercased())
        else {
            let allowed = AgentVerb.allCases.map { $0.rawValue }.joined(separator: ", ")
            return .invalid(reason: "`verb` must be one of: \(allowed).")
        }

        var steps: [AgentAction] = []
        if verb == .batch {
            let raw = (dict["actions"] as? [Any]) ?? []
            if raw.isEmpty { return .invalid(reason: "batch needs a non-empty `actions` list.") }
            if raw.count > maxBatchActions {
                return .invalid(
                    reason: "batch takes at most \(maxBatchActions) actions (got \(raw.count)); split the plan."
                )
            }
            for (index, element) in raw.enumerated() {
                guard let stepDict = element as? [String: Any] else {
                    return .invalid(reason: "actions[\(index)] must be an action object.")
                }
                switch decodeObject(stepDict, inBatch: true) {
                case .action(let step): steps.append(step)
                case .invalid(let reason): return .invalid(reason: "actions[\(index)]: \(reason)")
                }
            }
        } else if inBatch, !verb.isBatchable {
            return .invalid(
                reason: "\(verb.rawValue) can't run inside a batch; send it as its own agent_action call."
            )
        }

        if let problem = pointProblem(dict["target"], field: "target") ?? pointProblem(dict["to"], field: "to") {
            return .invalid(reason: problem)
        }

        let action = AgentAction(
            verb: verb,
            target: parseTarget(dict["target"]),
            to: parseTarget(dict["to"]),
            seconds: ArgumentCoercion.int(dict["seconds"]),
            text: dict["text"] as? String,
            replace: ArgumentCoercion.bool(dict["replace"]),
            key: dict["key"] as? String,
            modifiers: ArgumentCoercion.stringArray(dict["modifiers"]) ?? [],
            repeatCount: ArgumentCoercion.int(dict["repeat"]),
            direction: (dict["direction"] as? String).flatMap { CUScrollDirection(rawValue: $0.lowercased()) },
            amount: ArgumentCoercion.int(dict["amount"]),
            app: dict["app"] as? String,
            query: dict["query"] as? String,
            roles: ArgumentCoercion.stringArray(dict["roles"]) ?? [],
            option: (dict["option"] as? String).flatMap {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
            },
            region: parseRegion(dict["region"]),
            actions: steps,
            note: dict["note"] as? String,
            reason: dict["reason"] as? String
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
        let point = parsePoint(dict["point"])
        if mark == nil && describe == nil && point == nil { return nil }
        return AgentTarget(mark: mark, describe: describe, point: point)
    }

    private static func parsePoint(_ value: Any?) -> AgentPoint? {
        if let p = value as? [String: Any] {
            guard let x = ArgumentCoercion.double(p["x"]), let y = ArgumentCoercion.double(p["y"]) else {
                return nil
            }
            return AgentPoint(x: x, y: y)
        }
        if let pair = value as? [Any], pair.count == 2,
            let x = ArgumentCoercion.double(pair[0]), let y = ArgumentCoercion.double(pair[1])
        {
            return AgentPoint(x: x, y: y)
        }
        return nil
    }

    /// The validator checks neither tuple length nor nested `x`/`y` inside
    /// `anyOf`, so a malformed point gets its own reason instead of being
    /// silently dropped.
    private static func pointProblem(_ target: Any?, field: String) -> String? {
        guard let dict = target as? [String: Any], let raw = dict["point"], !(raw is NSNull) else { return nil }
        return parsePoint(raw) == nil
            ? "`\(field).point` takes two numbers, as {\"x\": <x>, \"y\": <y>} or [<x>, <y>]."
            : nil
    }

    private static func parseRegion(_ value: Any?) -> AgentRegion? {
        guard let r = value as? [String: Any],
            let x = ArgumentCoercion.double(r["x"]),
            let y = ArgumentCoercion.double(r["y"]),
            let width = ArgumentCoercion.double(r["width"]),
            let height = ArgumentCoercion.double(r["height"])
        else { return nil }
        return AgentRegion(x: x, y: y, width: width, height: height)
    }

    /// Verb-specific required-field check beyond the JSON schema (which can't
    /// express "click requires a target"). Returns a model-readable reason
    /// when something required for the chosen verb is missing.
    func semanticProblem() -> String? {
        switch verb {
        case .observe, .wait, .screenshot, .batch:
            return nil
        case .zoom:
            guard let region else { return "zoom needs a `region` {x, y, width, height} in screenshot pixels." }
            if region.width <= 0 || region.height <= 0 {
                return "zoom's `region` needs a positive width and height."
            }
            return nil
        case .hover:
            if target?.isEmpty ?? true {
                return "hover needs a `target` (a `mark`, `describe`, or `point`)."
            }
            return nil
        case .select:
            if target?.isEmpty ?? true {
                return "select needs a `target`: the popup, menu button, or combo box to pick from."
            }
            if option == nil { return "select needs the `option` title to pick." }
            return nil
        case .find:
            if (query?.isEmpty ?? true) && roles.isEmpty {
                return "find needs a `query` substring and/or `roles` filter."
            }
            return nil
        case .click, .clear, .doubleClick, .rightClick:
            if target?.isEmpty ?? true {
                return "\(verb.rawValue) needs a `target` (a `mark` number, a `describe`, or a `point`)."
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
            if let repeatCount, !(1 ... Self.maxKeyRepeat).contains(repeatCount) {
                return "press_key's `repeat` must be between 1 and \(Self.maxKeyRepeat)."
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
