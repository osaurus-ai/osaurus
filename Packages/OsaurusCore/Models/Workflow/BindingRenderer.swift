//
//  BindingRenderer.swift
//  osaurus
//
//  Resolves `{{input.x}}`, `{{nodes.<id>.output.y}}`, `{{run.<field>}}`,
//  `{{caller.<field>}}`, and `{{folders.<key>}}` references against a run's state. A string
//  that is exactly one reference yields the referenced value unchanged, so
//  bindings stay typed; mixed text interpolates (strings raw, everything
//  else as compact JSON). A node on a branch not taken binds as null.
//

import Foundation

public struct BindingContext: Sendable {
    public var input: JSONValue
    /// Completed node outputs. Skipped nodes are present as `.null`.
    public var outputs: [String: JSONValue]
    /// `{id, workspace}` of the run.
    public var run: JSONValue
    /// `{kind, agent_id, agent_name}` of whoever started the run.
    public var caller: JSONValue
    /// Declared folder key -> the folder bound on this Mac.
    public var folders: JSONValue
    /// Inside a `map` step: the current item and its position.
    public var item: JSONValue?
    public var index: Int?

    public init(
        input: JSONValue, outputs: [String: JSONValue] = [:], run: JSONValue = .null, caller: JSONValue = .null,
        folders: JSONValue = .null, item: JSONValue? = nil, index: Int? = nil
    ) {
        self.input = input
        self.outputs = outputs
        self.run = run
        self.caller = caller
        self.folders = folders
        self.item = item
        self.index = index
    }

    /// This context for one item of a map step.
    public func forItem(_ item: JSONValue, index: Int) -> BindingContext {
        var copy = self
        copy.item = item
        copy.index = index
        return copy
    }

    public static func foldersValue(_ bound: [String: String]) -> JSONValue {
        .object(bound.mapValues { .string($0) })
    }

    /// The fields `{{run.x}}` may name.
    public static let runFields: Set<String> = ["id", "workspace"]
    /// The fields `{{caller.x}}` may name. `channel` is an object
    /// (`{{caller.channel.sender_name}}`), null when no message started the run.
    public static let callerFields: Set<String> = ["kind", "agent_id", "agent_name", "channel"]
    /// The fields of `{{caller.channel.x}}`.
    public static let callerChannelFields: Set<String> = [
        "platform", "connection_id", "room_id", "room_name", "thread_id", "sender_id", "sender_name",
    ]

    public static func runValue(id: UUID, workspace: URL) -> JSONValue {
        .object(["id": .string(id.uuidString), "workspace": .string(workspace.path)])
    }

    public static func callerValue(_ caller: WorkflowCaller) -> JSONValue {
        .object([
            "kind": .string(caller.kind.rawValue),
            "agent_id": caller.agentID.map { .string($0.uuidString) } ?? .null,
            "agent_name": caller.agentName.map { .string($0) } ?? .null,
            "channel": caller.channelReply?.bindingValue ?? .null,
        ])
    }
}

public enum BindingRenderer {

    // swiftlint:disable:next force_try
    private static let pattern = try! NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)

    /// Every reference expression in `text`, trimmed.
    public static func references(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        }
    }

    /// Parsed reference: `input[.path]`, `nodes.<id>.output[.path]`,
    /// `run.<field>`, `caller.<field>`, or `folders.<key>`.
    public enum Reference: Equatable, Sendable {
        case input(path: String)
        case node(id: String, path: String)
        case run(field: String)
        case caller(field: String)
        case folder(key: String)
        /// The current item of a `map` step.
        case item(path: String)
        /// The current item's position in a `map` step, from 0.
        case index

        /// Only meaningful inside a map step's body.
        public var isMapScoped: Bool {
            switch self {
            case .item, .index: return true
            default: return false
            }
        }
    }

    public static func parse(reference raw: String) -> Reference? {
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let head = parts.first else { return nil }
        if head == "input" {
            return .input(path: parts.dropFirst().joined(separator: "."))
        }
        if head == "item" {
            return .item(path: parts.dropFirst().joined(separator: "."))
        }
        if raw == "index" {
            return .index
        }
        if head == "nodes", parts.count >= 3, !parts[1].isEmpty, parts[2] == "output" {
            return .node(id: parts[1], path: parts.dropFirst(3).joined(separator: "."))
        }
        if parts.count == 2, head == "run", BindingContext.runFields.contains(parts[1]) {
            return .run(field: parts[1])
        }
        if parts.count == 2, head == "caller", BindingContext.callerFields.contains(parts[1]) {
            return .caller(field: parts[1])
        }
        if parts.count == 3, head == "caller", parts[1] == "channel",
            BindingContext.callerChannelFields.contains(parts[2])
        {
            return .caller(field: "channel." + parts[2])
        }
        if parts.count == 2, head == "folders", !parts[1].isEmpty {
            return .folder(key: parts[1])
        }
        return nil
    }

    public static func resolve(_ raw: String, in ctx: BindingContext) -> JSONValue {
        switch parse(reference: raw) {
        case .input(let path)?:
            return path.isEmpty ? ctx.input : (ctx.input.value(atPath: path) ?? .null)
        case .node(let id, let path)?:
            guard let out = ctx.outputs[id] else { return .null }
            return path.isEmpty ? out : (out.value(atPath: path) ?? .null)
        case .run(let field)?:
            return ctx.run.value(atPath: field) ?? .null
        case .caller(let field)?:
            return ctx.caller.value(atPath: field) ?? .null
        case .folder(let key)?:
            return ctx.folders.objectValue?[key] ?? .null
        case .item(let path)?:
            guard let item = ctx.item else { return .null }
            return path.isEmpty ? item : (item.value(atPath: path) ?? .null)
        case .index?:
            return ctx.index.map { .number(Double($0)) } ?? .null
        case nil:
            return .null
        }
    }

    /// Renders one template string to a value.
    public static func renderValue(_ text: String, in ctx: BindingContext) -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let refs = references(in: trimmed)
        if refs.count == 1, trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}"),
            references(in: String(trimmed.dropFirst(2).dropLast(2))).isEmpty
        {
            return resolve(refs[0], in: ctx)
        }
        return .string(renderText(text, in: ctx))
    }

    /// Interpolates every reference as text.
    public static func renderText(_ text: String, in ctx: BindingContext) -> String {
        interpolate(text, in: ctx, format: textValue)
    }

    /// Like `renderText`, but objects and lists read as labelled lines and
    /// bullets. For text a person reads (dialog and reply messages); prompts
    /// keep the JSON.
    public static func renderReadableText(_ text: String, in ctx: BindingContext) -> String {
        interpolate(text, in: ctx, format: readableText)
    }

    private static func interpolate(
        _ text: String, in ctx: BindingContext, format: (JSONValue) -> String
    ) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let ref = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            out += format(resolve(ref, in: ctx))
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    // MARK: - Trust-splitting render

    /// A referenced value kept out of the rendered text because it came from
    /// outside the author's control: a node output (web text, email bodies,
    /// tool results) or, for runs started by a model, the input.
    public struct UntrustedReference: Equatable, Sendable {
        /// The token left in the text where the value would have gone.
        public var placeholder: String
        /// The reference as written, e.g. `nodes.fetch.output.body`.
        public var reference: String
        public var value: JSONValue
    }

    public struct SplitRendering: Equatable, Sendable {
        public var text: String
        public var untrusted: [UntrustedReference]
    }

    /// Whether a reference's value is under the workflow author's control.
    /// `run.*`, `caller.*`, and `folders.*` come from the app; `input` does
    /// when a person typed it; node outputs never do. `caller.channel` names
    /// the remote sender and room, which the sender controls.
    public static func isTrusted(_ reference: Reference?, trustInput: Bool) -> Bool {
        switch reference {
        case .caller(let field)?: return field != "channel" && !field.hasPrefix("channel.")
        case .run?, .folder?, .index?: return true
        case .input?: return trustInput
        // Items come from a node output (or the input, when a model
        // supplied it); treat them as data.
        case .node?, .item?: return false
        case nil: return true
        }
    }

    static func placeholder(_ index: Int) -> String { "[[ref:\(index)]]" }

    /// Like `renderText`, but untrusted references are replaced by
    /// `[[ref:N]]` placeholders and returned separately so the caller can
    /// put them where they count as data, not instructions.
    public static func renderTextSplittingUntrusted(_ text: String, in ctx: BindingContext, trustInput: Bool)
        -> SplitRendering
    {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        var untrusted: [UntrustedReference] = []
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let ref = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let value = resolve(ref, in: ctx)
            if isTrusted(parse(reference: ref), trustInput: trustInput) {
                out += textValue(value)
            } else {
                let token = placeholder(untrusted.count + 1)
                untrusted.append(UntrustedReference(placeholder: token, reference: ref, value: value))
                out += token
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return SplitRendering(text: out, untrusted: untrusted)
    }

    public static func render(_ binding: WorkflowBinding, in ctx: BindingContext) -> JSONValue {
        switch binding {
        case .template(let s):
            return renderValue(s, in: ctx)
        case .object(let map):
            var out: [String: JSONValue] = [:]
            for (key, template) in map { out[key] = renderValue(template, in: ctx) }
            return .object(out)
        case .values(let fields):
            var out: [String: JSONValue] = [:]
            for (key, value) in fields { out[key] = value.stringValue.map { renderValue($0, in: ctx) } ?? value }
            return .object(out)
        }
    }

    static func textValue(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): return s
        case .null: return ""
        case .number(let n):
            return n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return value.compactJSONString
        }
    }

    // MARK: - Readable text

    /// A value as a person reads it. Top-level fields are "Label" over the
    /// value, a blank line apart; lists are bullets; a list item that has a
    /// title-like field leads with it. Plain fields come before nested ones,
    /// each group alphabetical, since objects carry no order. Empty values
    /// are left out.
    static func readableText(_ value: JSONValue) -> String {
        switch value {
        case .object(let fields):
            return orderedKeys(fields).compactMap { key -> String? in
                let body: String
                switch fields[key]! {
                case .object(let inner): body = readableFields(inner, indent: "  ")
                case .array(let items): body = readableList(items, indent: "")
                case let scalar: body = textValue(scalar)
                }
                return body.isEmpty ? nil : readableLabel(key) + "\n" + body
            }.joined(separator: "\n\n")
        case .array(let items):
            return readableList(items, indent: "")
        default:
            return textValue(value)
        }
    }

    private static let titleKeys = ["title", "heading", "name", "label", "subject"]

    private static func isEmptyValue(_ value: JSONValue) -> Bool {
        switch value {
        case .null: return true
        case .string(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let items): return items.allSatisfy(isEmptyValue)
        case .object(let fields): return fields.values.allSatisfy(isEmptyValue)
        default: return false
        }
    }

    private static func isScalar(_ value: JSONValue) -> Bool {
        switch value {
        case .object, .array: return false
        default: return true
        }
    }

    private static func orderedKeys(_ fields: [String: JSONValue]) -> [String] {
        let keys = fields.keys.filter { !isEmptyValue(fields[$0]!) }.sorted()
        return keys.filter { isScalar(fields[$0]!) } + keys.filter { !isScalar(fields[$0]!) }
    }

    private static func readableLabel(_ key: String) -> String {
        let spaced = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// Continuation lines of a multi-line value line up under its first.
    private static func indented(_ text: String, _ indent: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\n" + indent)
    }

    /// Nested fields, one per line: "Label: value", or "Label" over its list
    /// or fields one step further in.
    private static func readableFields(_ fields: [String: JSONValue], indent: String) -> String {
        orderedKeys(fields).map { key in
            let label = indent + readableLabel(key)
            switch fields[key]! {
            case .object(let inner): return label + "\n" + readableFields(inner, indent: indent + "  ")
            case .array(let items): return label + "\n" + readableList(items, indent: indent + "  ")
            case let scalar: return label + ": " + indented(textValue(scalar), indent + "  ")
            }
        }.joined(separator: "\n")
    }

    private static func readableList(_ items: [JSONValue], indent: String) -> String {
        let bullet = indent.isEmpty ? "• " : "– "
        return items.filter { !isEmptyValue($0) }.map { item in
            switch item {
            case .object(var fields):
                if let key = titleKeys.first(where: { fields[$0].map(isScalar) == true && !isEmptyValue(fields[$0]!) }) {
                    let head = indent + bullet + indented(textValue(fields[key]!), indent + "  ")
                    fields[key] = nil
                    let rest = readableFields(fields, indent: indent + "  ")
                    return rest.isEmpty ? head : head + "\n" + rest
                }
                let rest = readableFields(fields, indent: indent + "  ")
                return indent + bullet + rest.dropFirst(indent.count + 2)
            case .array(let inner):
                return readableList(inner, indent: indent + "  ")
            default:
                return indent + bullet + indented(textValue(item), indent + "  ")
            }
        }.joined(separator: "\n")
    }
}
