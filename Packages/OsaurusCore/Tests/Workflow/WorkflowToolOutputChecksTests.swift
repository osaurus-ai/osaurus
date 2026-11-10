//
//  WorkflowToolOutputChecksTests.swift
//  osaurusTests
//
//  The checks that catch a workflow reading a tool field that is not
//  there: draft warnings against the tool's published schema, test-run
//  observations for a map over nothing, and state keys that are bindings
//  described in words instead of shown raw.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowToolOutputChecksTests {

    private static func search(outputSchema: JSONValue = .object([:])) -> WorkflowNode {
        WorkflowNode(
            id: "search", name: "Find resumes", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_search"))),
            input: .object(["pattern": "*", "target": "files", "path": "{{input.folder}}"]),
            outputSchema: outputSchema)
    }

    private static func parse(reading ref: String) -> WorkflowNode {
        WorkflowNode(
            id: "parse", name: "Parse", kind: .code(CodeSpec(source: "return {resumes: input.files || []}")),
            input: .object(["files": ref]))
    }

    private static func definition(_ nodes: [WorkflowNode]) -> WorkflowDefinition {
        WorkflowDefinition(
            nodes: nodes,
            edges: zip(nodes, nodes.dropFirst()).map { WorkflowEdge(from: $0.id, to: $1.id) })
    }

    private static func published(_ name: String) -> JSONValue? {
        name == "file_search" ? FolderToolOutputSchemas.fileSearch : nil
    }

    // MARK: - Draft warnings

    @Test func bindingToAFieldTheToolDoesNotReturnIsWarned() {
        let def = Self.definition([Self.search(), Self.parse(reading: "{{nodes.search.output.files}}")])
        let warnings = WorkflowValidator.warnings(def, toolOutputSchema: Self.published)
        let warning = warnings.first { $0.nodeID == "search" }
        #expect(warning?.message.contains("`parse` reads `{{nodes.search.output.files}}`") == true)
        #expect(warning?.message.contains("returns no `files` field") == true)
        #expect(warning?.message.contains("entries") == true, "names the real fields")
    }

    @Test func bindingToARealFieldIsNotWarned() {
        let fine = Self.definition([
            Self.search(), Self.parse(reading: "{{nodes.search.output.entries}}"),
            WorkflowNode(
                id: "each", name: "Each",
                kind: .map(MapSpec(items: "{{nodes.search.output.entries}}", step: .object(["kind": .string("wait")])))),
        ])
        #expect(WorkflowValidator.warnings(fine, toolOutputSchema: Self.published).isEmpty)
        let nested = Self.definition([Self.search(), Self.parse(reading: "{{nodes.search.output.entries.0.path}}")])
        #expect(WorkflowValidator.warnings(nested, toolOutputSchema: Self.published).isEmpty)
        let wrongNested = Self.definition([Self.search(), Self.parse(reading: "{{nodes.search.output.entries.0.file}}")])
        #expect(
            WorkflowValidator.warnings(wrongNested, toolOutputSchema: Self.published)
                .contains { $0.message.contains("returns no `file` field") })
    }

    @Test func emptySchemaOnAToolWithoutOneIsWarnedOnlyWhenRead() {
        let none: (String) -> JSONValue? = { _ in nil }
        let read = Self.definition([Self.search(), Self.parse(reading: "{{nodes.search.output.files}}")])
        #expect(
            WorkflowValidator.warnings(read, toolOutputSchema: none)
                .contains { $0.message.contains("publishes no output schema") })
        let unread = Self.definition([Self.search()])
        #expect(WorkflowValidator.warnings(unread, toolOutputSchema: none).isEmpty)
        let declared = Self.definition([
            Self.search(
                outputSchema: .object([
                    "type": .string("object"),
                    "properties": .object(["files": .object(["type": .string("array")])]),
                ])),
            Self.parse(reading: "{{nodes.search.output.files}}"),
        ])
        #expect(WorkflowValidator.warnings(declared, toolOutputSchema: none).isEmpty)
        // Without the registry lookup (older callers) nothing changes.
        #expect(WorkflowValidator.warnings(read).isEmpty)
    }

    @Test func readsFromTheWorkflowOutputAreChecked() {
        var def = Self.definition([Self.search()])
        def.output = .object(["found": "{{nodes.search.output.matches}}"])
        #expect(
            WorkflowValidator.warnings(def, toolOutputSchema: Self.published)
                .contains { $0.message.contains("the workflow output reads") })
    }

    // MARK: - Test-run observations

    private static func run(_ def: WorkflowDefinition, _ records: [String: (input: JSONValue?, output: JSONValue)])
        -> WorkflowRun
    {
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "Screener", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .test), input: .object(["folder": .string("/tmp/resumes")]),
            nodeIDs: def.nodes.map(\.id))
        for (id, record) in records {
            run.update(id) {
                $0.status = .done
                $0.input = record.input
                $0.output = record.output
            }
        }
        run.status = .completed
        return run
    }

    private static let entries: JSONValue = .array([
        .object(["name": .string("jane.pdf"), "path": .string("/tmp/resumes/jane.pdf"), "type": .string("file")]),
        .object(["name": .string("sam.docx"), "path": .string("/tmp/resumes/sam.docx"), "type": .string("file")]),
    ])

    @Test func mapOverNothingNamesWhatTheUpstreamStepReallyHad() {
        let def = Self.definition([
            Self.search(), Self.parse(reading: "{{nodes.search.output}}"),
            WorkflowNode(
                id: "screen", name: "Screen",
                kind: .map(MapSpec(items: "{{nodes.parse.output.resumes}}", step: .object(["kind": .string("wait")])))),
        ])
        let found: JSONValue = .object(["kind": .string("search"), "entries": Self.entries, "match_count": .number(2)])
        let run = Self.run(
            def,
            [
                "search": (nil, found),
                "parse": (.object(["files": found]), .object(["resumes": .array([]), "count": .number(0)])),
                "screen": (nil, .object(["items": .array([]), "count": .number(0), "failed": .array([])])),
            ])
        let notes = WorkflowRunObservations.notes(run, definition: def)
        #expect(notes.count == 1, "\(notes)")
        let note = notes.first ?? ""
        #expect(note.contains("Map `screen` ran over 0 items"))
        #expect(note.contains("`{{nodes.parse.output.resumes}}` is an empty list"))
        #expect(note.contains("`parse` returned {count, resumes (0 items)}"))
        #expect(note.contains("entries (2 items)"), "shows where the list really was: \(note)")
    }

    @Test func toolStepWithOnlyEmptyListsIsNoted() {
        let def = Self.definition([Self.search()])
        let run = Self.run(
            def,
            [
                "search": (
                    .object(["pattern": .string("*.pdf"), "target": .string("files")]),
                    .object(["kind": .string("search"), "entries": .array([]), "match_count": .number(0)])
                )
            ])
        let notes = WorkflowRunObservations.notes(run, definition: def)
        #expect(notes.count == 1)
        #expect(notes.first?.contains("`search` (file_search) returned an empty `entries` list") == true)
        #expect(notes.first?.contains("*.pdf") == true, "shows the arguments")
    }

    @Test func runThatDidItsWorkHasNoNotes() {
        let def = Self.definition([
            Self.search(),
            WorkflowNode(
                id: "screen", name: "Screen",
                kind: .map(MapSpec(items: "{{nodes.search.output.entries}}", step: .object(["kind": .string("wait")])))),
        ])
        let run = Self.run(
            def,
            [
                "search": (nil, .object(["entries": Self.entries])),
                "screen": (nil, .object(["items": .array([.null, .null]), "count": .number(2), "failed": .array([])])),
            ])
        #expect(WorkflowRunObservations.notes(run, definition: def).isEmpty)
    }

    // MARK: - State summary

    @Test func stateKeyThatIsABindingReadsInWords() {
        let bound = WorkflowSummary.stateKind(StateSpec(action: .get, table: "seen", key: "{{nodes.parse.output.role}}"))
        #expect(bound == "Reads the entry for “role” in seen")
        #expect(!bound.contains("{{"))
        let stored = WorkflowSummary.stateKind(StateSpec(action: .set, key: "{{input.email}}", value: "x"))
        #expect(stored == "Remembers the entry for “email”")
        #expect(WorkflowSummary.keyText("seen-{{ input.email }}") == "seen-email")
        #expect(WorkflowSummary.keyText("{{nodes.parse.output}}") == "parse")
        #expect(WorkflowSummary.stateKind(StateSpec(action: .get, table: "seen", key: "k")) == "Reads “k” in seen")
    }
}
