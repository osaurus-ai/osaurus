//
//  WorkflowSummary.swift
//  osaurus
//
//  A workflow in plain words: what you fill in, the steps it takes, and
//  what you get back. Shared by the starter preview, the workflow tab
//  header, and the Architect's Overview.
//

import Foundation

enum WorkflowSummary {
    struct Step: Equatable, Identifiable {
        let id: String
        let name: String
        let kind: String
        /// SF Symbol for the kind of work, so steps read at a glance.
        let icon: String
    }

    static func inputs(_ def: WorkflowDefinition) -> [String] {
        WorkflowFormFields.fields(fromInputSchema: def.inputSchema).map(\.label)
    }

    static func outputs(_ def: WorkflowDefinition) -> [String] {
        WorkflowOutputLayout.labels(schema: def.outputSchema)
    }

    /// Steps in the order they run; declared order when the graph has a cycle.
    static func steps(_ def: WorkflowDefinition) -> [Step] {
        let order = WorkflowValidator.topologicalOrder(def) ?? def.nodes.map(\.id)
        return order.compactMap { id in
            def.node(id).map { Step(id: $0.id, name: $0.name, kind: kind($0), icon: icon($0)) }
        }
    }

    static func kind(_ node: WorkflowNode) -> String {
        switch node.kind {
        case nil: return L("Planned")
        case .dialog: return L("Asks you")
        case .code(let spec): return spec.language == .python ? L("Runs Python") : L("Runs code")
        case .tool(let spec): return L("Uses the \(WorkflowFormFields.humanized(spec.tool.name).lowercased()) tool")
        case .http(let spec): return L("Calls \(spec.literalHost ?? spec.allowedHosts.first ?? "a web API")")
        case .wait: return L("Waits")
        case .map(let spec): return L("For each item: \(kind(spec.body(parentID: node.id)).lowercased())")
        case .workflow(let spec): return L("Runs the workflow \(spec.workflow)")
        case .state(let spec): return stateKind(spec)
        case .reply: return L("Replies in the conversation")
        case .media(let spec): return spec.summary
        case .agent(let spec):
            return spec.workspace == nil ? L("Asks \(spec.agent)") : L("Asks \(spec.agent), a teammate's agent")
        case .inference(let spec):
            switch spec.mode {
            case .generate: return L("Uses a model")
            case .decide: return L("Picks a path")
            case .agentic: return L("Uses a model and tools")
            }
        }
    }

    static func stateKind(_ spec: StateSpec) -> String {
        let raw = spec.key ?? ""
        let key = WorkflowFormFields.humanized(keyText(raw)).lowercased()
        let table = spec.table ?? StateSpec.defaultTable
        let named = table == StateSpec.defaultTable ? nil : WorkflowFormFields.humanized(table).lowercased()
        guard BindingRenderer.references(in: raw).isEmpty else {
            switch spec.action {
            case .get:
                return named.map { L("Reads the entry for “\(key)” in \($0)") } ?? L("Reads the stored entry for “\(key)”")
            case .set:
                return named.map { L("Remembers the entry for “\(key)” in \($0)") } ?? L("Remembers the entry for “\(key)”")
            case .increment:
                return named.map { L("Counts up the entry for “\(key)” in \($0)") } ?? L("Counts up the entry for “\(key)”")
            case .delete:
                return named.map { L("Forgets the entry for “\(key)” in \($0)") } ?? L("Forgets the entry for “\(key)”")
            case .list: return named.map { L("Lists \($0)") } ?? L("Lists stored values")
            case .clear: return named.map { L("Clears \($0)") } ?? L("Clears stored values")
            }
        }
        switch spec.action {
        case .get: return named.map { L("Reads “\(key)” in \($0)") } ?? L("Reads the stored “\(key)”")
        case .set: return named.map { L("Remembers “\(key)” in \($0)") } ?? L("Remembers “\(key)”")
        case .increment: return named.map { L("Counts up “\(key)” in \($0)") } ?? L("Counts up “\(key)”")
        case .delete: return named.map { L("Forgets “\(key)” in \($0)") } ?? L("Forgets “\(key)”")
        case .list: return named.map { L("Lists \($0)") } ?? L("Lists stored values")
        case .clear: return named.map { L("Clears \($0)") } ?? L("Clears stored values")
        }
    }

    // swiftlint:disable:next force_try
    private static let bindingPattern = try! NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)

    /// `key` with each `{{…}}` replaced by the name of what it reads:
    /// "{{nodes.parse.output.role}}" is "role", "seen-{{input.email}}" is
    /// "seen-email".
    static func keyText(_ key: String) -> String {
        var text = key
        let range = NSRange(key.startIndex..., in: key)
        for match in bindingPattern.matches(in: key, range: range).reversed() {
            guard let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: key) else {
                continue
            }
            text.replaceSubrange(whole, with: referenceName(String(key[inner])))
        }
        return text
    }

    private static func referenceName(_ ref: String) -> String {
        let lastField: (String) -> String? = { path in
            path.split(separator: ".").last(where: { Int($0) == nil }).map(String.init)
        }
        switch BindingRenderer.parse(reference: ref) {
        case .input(let path)?: return lastField(path) ?? L("input")
        case .node(let id, let path)?: return lastField(path) ?? id
        case .item(let path)?: return lastField(path) ?? L("item")
        case .index?: return L("position")
        case .run(let field)?, .caller(let field)?: return lastField(field) ?? field
        case .folder(let key)?: return key
        case nil: return lastField(ref) ?? ref
        }
    }

    static func icon(_ node: WorkflowNode) -> String {
        switch node.kind {
        case nil: return "circle.dashed"
        case .dialog: return "questionmark.bubble"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .tool: return "wrench.and.screwdriver"
        case .http: return "network"
        case .wait: return "clock"
        case .map: return "square.stack.3d.down.right"
        case .workflow: return "point.3.connected.trianglepath.dotted"
        case .state: return "tray.full"
        case .reply: return "arrowshape.turn.up.left"
        case .media(let spec): return spec.action == .video ? "film" : "photo.on.rectangle.angled"
        case .agent(let spec): return spec.workspace == nil ? "person.crop.circle" : "person.2"
        case .inference(let spec):
            switch spec.mode {
            case .generate: return "sparkles"
            case .decide: return "arrow.triangle.branch"
            case .agentic: return "wand.and.stars"
            }
        }
    }

    /// A condition in plain words: "choice = new", "score > 3 and tier in
    /// [gold, silver]", "not (body is empty)".
    static func condition(_ condition: WorkflowCondition) -> String {
        if let all = condition.all { return all.map(wrapped).joined(separator: " and ") }
        if let any = condition.any { return any.map(wrapped).joined(separator: " or ") }
        if let not = condition.not, let inner = not.first { return "not (" + Self.condition(inner) + ")" }
        let subject = condition.path.isEmpty ? L("output") : condition.path
        let value = condition.value.map { WorkflowFormFields.text($0) } ?? "null"
        switch condition.op {
        case .equals: return "\(subject) = \(value)"
        case .notEquals: return "\(subject) ≠ \(value)"
        case .in: return "\(subject) in \(value)"
        case .notIn: return "\(subject) not in \(value)"
        case .exists: return "\(subject) exists"
        case .notExists: return "\(subject) is missing"
        case .isEmpty: return "\(subject) is empty"
        case .notEmpty: return "\(subject) is not empty"
        case .isTrue: return "\(subject) is true"
        case .isFalse: return "\(subject) is false"
        case .greaterThan: return "\(subject) > \(value)"
        case .greaterOrEqual: return "\(subject) ≥ \(value)"
        case .lessThan: return "\(subject) < \(value)"
        case .lessOrEqual: return "\(subject) ≤ \(value)"
        case .contains: return "\(subject) contains \(value)"
        case .notContains: return "\(subject) does not contain \(value)"
        case .startsWith: return "\(subject) starts with \(value)"
        case .endsWith: return "\(subject) ends with \(value)"
        case .matches: return "\(subject) matches \(value)"
        }
    }

    private static func wrapped(_ condition: WorkflowCondition) -> String {
        condition.isGroup ? "(" + Self.condition(condition) + ")" : Self.condition(condition)
    }

    /// "You fill in Topic and Tone · 3 steps · You get Post"
    static func sentence(_ def: WorkflowDefinition) -> String {
        var parts: [String] = []
        let inputs = inputs(def)
        if !inputs.isEmpty { parts.append(L("You fill in \(list(inputs))")) }
        let count = def.nodes.count
        if count > 0 { parts.append(count == 1 ? L("1 step") : L("\(count) steps")) }
        let outputs = outputs(def)
        if !outputs.isEmpty { parts.append(L("You get \(list(outputs))")) }
        return parts.joined(separator: " · ")
    }

    /// A stored or returned value on one short line: text as is, a list
    /// joined, an object as "key: value" pairs, nesting elided.
    static func preview(_ value: JSONValue, limit: Int = 140) -> String {
        func scalar(_ v: JSONValue) -> String? {
            switch v {
            case .string(let s): return s
            case .number: return BindingRenderer.textValue(v)
            case .bool(let b): return b ? L("Yes") : L("No")
            case .null: return "—"
            case .array, .object: return nil
            }
        }
        let text: String
        switch value {
        case .array(let items):
            text = items.map { scalar($0) ?? "…" }.joined(separator: ", ")
        case .object(let fields):
            text = fields.keys.sorted().map { "\($0): \(scalar(fields[$0]!) ?? "…")" }.joined(separator: " · ")
        default:
            text = scalar(value) ?? ""
        }
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }

    /// A model slot by the steps that use it: "Model for Write and Check",
    /// or "Model" when no step names it.
    static func slotLabel(_ slot: String, in def: WorkflowDefinition?) -> String {
        let steps = slotSteps(slot, in: def)
        return steps.isEmpty ? L("Model") : L("Model for \(list(steps))")
    }

    /// The names of the model steps that run on `slot`.
    static func slotSteps(_ slot: String, in def: WorkflowDefinition?) -> [String] {
        (def?.nodes ?? []).compactMap { node -> String? in
            if case .inference(let spec) = node.kind, spec.modelSlot == slot { return node.name }
            return nil
        }
    }

    static func list(_ items: [String]) -> String {
        ListFormatter.localizedString(byJoining: items)
    }
}
