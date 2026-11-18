//
//  WorkflowRunObservations.swift
//  osaurus
//
//  Signs that a run finished without doing its work: a map over no items,
//  or a tool step that came back with only empty lists. Advisory: the run
//  still counts as passed, but the Architect hears what the steps really
//  returned, so a binding to a field the tool never returns is caught at
//  the first test instead of shipping.
//

import Foundation

enum WorkflowRunObservations {
    /// One line per suspicious step of `run`, judged against `definition`.
    static func notes(_ run: WorkflowRun, definition: WorkflowDefinition) -> [String] {
        let records = Dictionary(run.nodes.map { ($0.nodeID, $0) }, uniquingKeysWith: { first, _ in first })
        var notes: [String] = []
        for node in definition.nodes {
            guard let record = records[node.id], record.status == .done || record.status == .pinned,
                let output = record.output
            else { continue }
            switch node.kind {
            case .map(let spec)?:
                guard output.value(atPath: "items")?.arrayValue?.isEmpty == true,
                    output.value(atPath: "failed")?.arrayValue?.isEmpty ?? true
                else { continue }
                notes.append(emptyMapNote(node.id, items: spec.items, run: run, records: records))
            case .tool(let spec)?:
                guard let empty = emptyLists(output) else { continue }
                var note =
                    "`\(node.id)` (\(spec.tool.name)) returned an empty "
                    + empty.map { "`\($0)`" }.joined(separator: ", ") + " list, so later steps had nothing to work on."
                if let input = record.input { note += " It was called with " + clipped(input) + "." }
                notes.append(note + " The run passed; check the arguments are what you meant.")
            default:
                continue
            }
        }
        return notes
    }

    private static func emptyMapNote(
        _ id: String, items: String, run: WorkflowRun, records: [String: NodeRun]
    ) -> String {
        var note = "Map `\(id)` ran over 0 items, so its step never ran. The run passed, but nothing was done."
        guard let ref = BindingRenderer.references(in: items).first else { return note }
        switch BindingRenderer.parse(reference: ref) {
        case .node(let source, let path)?:
            guard let upstream = records[source]?.output else { return note }
            let value = path.isEmpty ? upstream : upstream.value(atPath: path)
            note += " `{{\(ref)}}` " + (value == nil ? "is missing" : "is " + shape(value!)) + "."
            note += " `\(source)` returned " + fields(upstream) + "."
            if let input = records[source]?.input, case .object = input {
                note += " Its input had " + fields(input)
                    + ". If `\(source)` reads a field its input does not have, read the one that holds the list."
            }
        case .input(let path)?:
            let value = path.isEmpty ? run.input : run.input.value(atPath: path)
            note += " `{{\(ref)}}` " + (value.map { "is " + shape($0) } ?? "is missing from the input") + "."
        default:
            break
        }
        return note
    }

    /// The names of `output`'s list fields when it has some and every one is
    /// empty.
    private static func emptyLists(_ output: JSONValue) -> [String]? {
        guard case .object(let fields) = output else { return nil }
        let lists = fields.filter { $0.value.arrayValue != nil }
        guard !lists.isEmpty, lists.allSatisfy({ $0.value.arrayValue?.isEmpty == true }) else { return nil }
        return lists.keys.sorted()
    }

    /// "{entries (21 items), match_count}": the top two levels of an object.
    static func fields(_ value: JSONValue, depth: Int = 2) -> String {
        guard case .object(let object) = value else { return shape(value) }
        guard !object.isEmpty else { return "{}" }
        let limit = 12
        var parts = object.keys.sorted().prefix(limit).map { key -> String in
            let field = object[key]!
            switch field {
            case .array(let list): return "\(key) (\(list.count) item\(list.count == 1 ? "" : "s"))"
            case .object where depth > 1: return "\(key): " + fields(field, depth: depth - 1)
            default: return key
            }
        }
        if object.count > limit { parts.append("…") }
        return "{" + parts.joined(separator: ", ") + "}"
    }

    private static func shape(_ value: JSONValue) -> String {
        switch value {
        case .array(let list): return list.isEmpty ? "an empty list" : "a list of \(list.count)"
        case .object(let object): return object.isEmpty ? "an empty object" : "an object"
        case .string(let text): return text.isEmpty ? "an empty string" : "a string, not a list"
        case .null: return "null"
        case .number: return "a number, not a list"
        case .bool: return "a boolean, not a list"
        }
    }

    private static func clipped(_ value: JSONValue) -> String {
        let text = value.compactJSONString
        return text.count <= 300 ? text : String(text.prefix(300)) + "…"
    }
}
