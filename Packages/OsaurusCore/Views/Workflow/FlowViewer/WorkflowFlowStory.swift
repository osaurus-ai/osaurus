//
//  WorkflowFlowStory.swift
//  osaurus
//
//  A workflow's run in the words the full view uses: what you gave, what
//  each step made, what you got, and whether anything leaves this Mac.
//  Also a map step's items, live from the runner or final from its output.
//

import Foundation

enum WorkflowFlowStory {
    // MARK: - What went in and came out

    /// A labelled value: "Topic" and "Solar panels". The text is empty
    /// before a run fills it in.
    struct Entry: Equatable, Identifiable {
        /// The schema key, or the entry's position when there is none.
        /// Titles repeat, and a `ForEach` over repeated ids traps.
        var key = ""
        let label: String
        let text: String
        var id: String { key }
    }

    /// What the workflow asks for, with the run's answers when there is one.
    static func given(_ def: WorkflowDefinition, run: WorkflowRun?) -> [Entry] {
        WorkflowFormFields.fields(fromInputSchema: def.inputSchema).map { field in
            guard let run else { return Entry(key: field.key, label: field.label, text: "") }
            let value = run.input.value(atPath: field.key)
            return Entry(key: field.key, label: field.label, text: value.flatMap { peek($0, limit: 80) } ?? "—")
        }
    }

    /// What the workflow gives back: the finished run's result by field,
    /// else the names of the fields it will have.
    static func gotten(_ def: WorkflowDefinition, run: WorkflowRun?) -> [Entry] {
        guard let output = run?.output else {
            return WorkflowSummary.outputs(def).enumerated().map { Entry(key: "\($0.offset)", label: $0.element, text: "") }
        }
        if let fields = WorkflowOutputLayout.fields(output, schema: def.outputSchema) {
            return fields.map { Entry(key: $0.key, label: $0.label, text: clip(firstLine($0.text), 80)) }
        }
        return peek(output, limit: 120).map { [Entry(label: "", text: $0)] } ?? []
    }

    /// A line under what you get, saying where the run is when it has no
    /// result to show: on its way, stopped, or never started.
    static func endNote(_ def: WorkflowDefinition, run: WorkflowRun?) -> String? {
        guard let run else { return nil }
        switch run.status {
        case .running, .awaitingUser:
            return L("On its way…")
        case .failed:
            let step = run.error?.nodeID.flatMap { def.node($0)?.name }
            return step.map { L("It stopped at “\($0)”.") } ?? L("It stopped before the end.")
        case .cancelled:
            return L("It was stopped before the end.")
        case .needsSetup:
            return L("It needs setting up before it can run.")
        case .completed:
            return gotten(def, run: run).isEmpty ? L("It finished.") : nil
        }
    }

    /// What a step made, on one short line: "20 items", the first line of a
    /// text, or its first fields; nil when there is nothing to show.
    static func peek(_ value: JSONValue?, limit: Int = 48) -> String? {
        guard let value else { return nil }
        switch value {
        case .null:
            return nil
        case .array(let items):
            return items.count == 1 ? L("1 item") : L("\(items.count) items")
        case .string(let text):
            let line = firstLine(text)
            return line.isEmpty ? nil : clip(line, limit)
        case .object(let fields):
            if fields.isEmpty { return nil }
            if case .array? = fields["items"] { return peek(fields["items"], limit: limit) }
            if fields.count == 1, let only = fields.values.first { return peek(only, limit: limit) }
            let text = WorkflowSummary.preview(value, limit: limit)
            return text.isEmpty ? nil : text
        case .number, .bool:
            return WorkflowSummary.preview(value, limit: limit)
        }
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }

    static func tokenText(_ count: Int) -> String {
        count == 1 ? L("1 token") : L("\(WorkflowStepRisk.compact(count)) tokens")
    }

    // MARK: - Where the data goes

    static let modelKinds: Set<WorkflowStepBadge.Kind> = [.cloudModel, .localModel]

    /// The kinds of access a step's details list, in the order it shows them.
    static let privacyKinds: [WorkflowStepBadge.Kind] = [.network, .secrets, .files, .shell, .browser, .mac]

    /// The steps that send data off this Mac, and those that might.
    struct Reach: Equatable {
        /// Steps whose model runs on a provider.
        var cloud: [String] = []
        /// Steps that reach a website, an API, or an MCP server, or drive a
        /// browser.
        var online: [String] = []
        /// Model steps with no model chosen yet, or that fall back to a
        /// provider when this Mac has no model.
        var unsure: [String] = []

        var steps: Set<String> { Set(cloud + online + unsure) }

        var title: String {
            switch (cloud.isEmpty, online.isEmpty) {
            case (false, false): return L("Goes online · uses a cloud model")
            case (false, true): return L("Uses a cloud model")
            case (true, false): return L("Goes online")
            case (true, true): return unsure.isEmpty ? L("Stays on this Mac") : L("May leave this Mac")
            }
        }

        var detail: String {
            if steps.isEmpty { return L("Nothing this workflow does leaves this Mac.") }
            var parts: [String] = []
            if !cloud.isEmpty { parts.append(L("Steps that use a cloud model send what they read to the provider.")) }
            if !online.isEmpty { parts.append(L("Some steps reach websites or online services.")) }
            if !unsure.isEmpty { parts.append(L("Where some steps run depends on the model they end up using.")) }
            parts.append(L("Click to show those steps."))
            return parts.joined(separator: " ")
        }
    }

    static func reach(_ order: [String], badges: [String: [WorkflowStepBadge]]) -> Reach {
        let unchosen = L("Model not chosen")
        let fallback = L("Local model, else provider")
        var out = Reach()
        for id in order {
            let list = badges[id] ?? []
            if list.contains(where: { $0.kind == .cloudModel }) {
                out.cloud.append(id)
            } else if list.contains(where: { $0.kind == .localModel && ($0.label == unchosen || $0.label == fallback) }) {
                out.unsure.append(id)
            }
            if list.contains(where: { $0.kind == .network || $0.kind == .browser }) { out.online.append(id) }
        }
        return out
    }

    // MARK: - Map items

    /// A map step's items: each one's state, and once known its result or
    /// its error.
    struct MapItems: Equatable {
        var states: [MapItemState]
        var results: [JSONValue]
        var errors: [Int: String]

        var done: Int { states.filter { $0 == .done }.count }
        var running: Int { states.filter { $0 == .running }.count }
        var failed: Int { states.filter { $0 == .failed }.count }
    }

    /// The live states while the step runs, else the states its output
    /// records (`items`, with `failed` items by index); nil before either.
    static func mapItems(_ record: NodeRun?) -> MapItems? {
        guard let record else { return nil }
        if let live = record.mapItems { return MapItems(states: live, results: [], errors: [:]) }
        guard let results = record.output?.value(atPath: "items")?.arrayValue else { return nil }
        var errors: [Int: String] = [:]
        for entry in record.output?.value(atPath: "failed")?.arrayValue ?? [] {
            guard let index = entry.value(atPath: "index")?.numberValue else { continue }
            errors[Int(index)] = entry.value(atPath: "error")?.stringValue ?? ""
        }
        let states = results.indices.map { errors[$0] == nil ? MapItemState.done : .failed }
        return MapItems(states: states, results: results, errors: errors)
    }

    /// The most item dots a map step draws; the rest are counted.
    static let mapItemLimit = 400
}
