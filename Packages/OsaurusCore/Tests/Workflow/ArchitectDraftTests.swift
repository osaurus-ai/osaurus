//
//  ArchitectDraftTests.swift
//  OsaurusCoreTests
//
//  The Architect's draft: patch op parsing, atomic patches, the diff the
//  version history and direct-edit summaries read, the draft store's
//  turn context and undo, the tool gates, and the tool surface the
//  composer gives the Architect versus every other agent.
//

import Foundation
import Testing

@testable import OsaurusCore

private func json(_ text: String) -> JSONValue {
    guard let value = JSONValue.parse(text) else { fatalError("bad fixture JSON: \(text)") }
    return value
}

private func ops(_ text: String) throws -> [WorkflowDraftOp] {
    guard case .array(let items) = json(text) else { return [] }
    return try items.map(WorkflowDraftOp.parse)
}

@Suite
struct WorkflowDraftPatcherTests {

    @Test
    func parse_rejectsUnknownAndIncompleteOps() {
        #expect(throws: WorkflowDraftOp.ParseError.self) { try WorkflowDraftOp.parse(json(#"{"op": "rename"}"#)) }
        #expect(throws: WorkflowDraftOp.ParseError.self) { try WorkflowDraftOp.parse(json(#"{"name": "x"}"#)) }
        #expect(throws: WorkflowDraftOp.ParseError.self) {
            try WorkflowDraftOp.parse(json(#"{"op": "update_node", "node": {"name": "x"}}"#))
        }
        #expect(throws: WorkflowDraftOp.ParseError.self) {
            try WorkflowDraftOp.parse(json(#"{"op": "plan_placeholder", "name": "A"}"#))
        }
    }

    @Test
    func parse_updateNodeRefusesFieldsOutsideNode() {
        do {
            _ = try WorkflowDraftOp.parse(
                json(#"{"op": "update_node", "id": "ph", "input": {"path": "x"}, "node": {"kind": "tool", "tool": "file_write"}}"#))
            Issue.record("expected a parse error")
        } catch let error as WorkflowDraftOp.ParseError {
            #expect(error.message.contains("`input`"), "\(error.message)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test
    func parse_updateNodeTakesItsTargetFromNodeIdWhenTheOpHasNone() throws {
        let op = try WorkflowDraftOp.parse(
            json(#"{"op": "update_node", "node": {"id": "lookup", "name": "Find"}}"#))
        #expect(op == .updateNode(id: "lookup", fields: ["id": .string("lookup"), "name": .string("Find")]))
        let renamed = try WorkflowDraftOp.parse(
            json(#"{"op": "update_node", "id": "lookup", "node": {"id": "find"}}"#))
        #expect(renamed == .updateNode(id: "lookup", fields: ["id": .string("find")]))
    }

    @Test
    func parse_declareSlotIgnoresTheOpKey() throws {
        let op = try WorkflowDraftOp.parse(
            json(#"{"op": "declare_slot", "slot": "decision", "preferred": "openai/gpt-5", "needs_tool_use": true}"#))
        #expect(op == .declareSlot(ModelRequirement(slot: "decision", preferred: "openai/gpt-5", needsToolUse: true)))
    }

    @Test
    func placeholdersThenFill_producesARunnableShape() throws {
        let laid = try WorkflowDraftPatcher.apply(
            try ops(
                #"""
                [
                  {"op": "plan_placeholder", "id": "fetch", "name": "Fetch", "intent": "Get the record"},
                  {"op": "plan_placeholder", "id": "sum", "intent": "Summarize it"},
                  {"op": "add_edge", "from": "fetch", "to": "sum"},
                  {"op": "set_info", "name": "Digest", "summary": "Fetch then summarize"}
                ]
                """#),
            to: WorkflowDefinition())
        #expect(laid.definition.nodes.map(\.id) == ["fetch", "sum"])
        #expect(laid.definition.nodes.allSatisfy { $0.kind == nil })
        #expect(laid.definition.nodes[1].name == "sum")
        #expect(laid.name == "Digest")
        #expect(laid.touchedNodeIDs == ["fetch", "sum"])

        let filled = try WorkflowDraftPatcher.apply(
            try ops(
                #"""
                [{"op": "update_node", "id": "fetch", "node": {
                    "kind": "code",
                    "code": {"source": "function run(input, ctx) { return {} }", "network": ["api.example.com"]}
                }}]
                """#),
            to: laid.definition)
        guard case .code(let spec) = filled.definition.node("fetch")?.kind else {
            Issue.record("fetch should be a code node")
            return
        }
        #expect(spec.network == ["api.example.com"])
        #expect(filled.definition.node("fetch")?.name == "Fetch")
        #expect(filled.touchedNodeIDs == ["fetch"])
    }

    @Test
    func failingOp_leavesTheDefinitionUnchanged() throws {
        let start = WF.intake()
        do {
            _ = try WorkflowDraftPatcher.apply(
                try ops(
                    #"""
                    [
                      {"op": "remove_node", "id": "notify"},
                      {"op": "add_edge", "from": "onboard", "to": "missing"}
                    ]
                    """#),
                to: start)
            Issue.record("expected a failure")
        } catch let failure as WorkflowDraftPatcher.Failure {
            #expect(failure.index == 1)
            #expect(failure.message.contains("missing"))
        }
        #expect(start.node("notify") != nil)
    }

    @Test
    func removeNode_dropsItsEdges_andIdsCannotChange() throws {
        let result = try WorkflowDraftPatcher.apply(try ops(#"[{"op": "remove_node", "id": "onboard"}]"#), to: WF.intake())
        #expect(result.definition.edges.contains { $0.from == "onboard" || $0.to == "onboard" } == false)
        #expect(throws: WorkflowDraftPatcher.Failure.self) {
            try WorkflowDraftPatcher.apply(
                try ops(#"[{"op": "update_node", "id": "lookup", "node": {"id": "find"}}]"#), to: WF.intake())
        }
    }

    @Test
    func removeEdge_ofARemovedNode_isAlreadyDone_butAnUnknownEdgeFails() throws {
        let edge = try #require(WF.intake().edges.first { $0.from == "onboard" || $0.to == "onboard" })
        let result = try WorkflowDraftPatcher.apply(
            [.removeNode(id: "onboard"), .removeEdge(from: edge.from, to: edge.to)], to: WF.intake())
        #expect(result.definition.node("onboard") == nil)
        #expect(throws: WorkflowDraftPatcher.Failure.self) {
            try WorkflowDraftPatcher.apply([.removeEdge(from: edge.from, to: edge.to)], to: result.definition)
        }
    }

    @Test
    func addExample_removeDropsIt() throws {
        let added = try WorkflowDraftPatcher.apply(
            try ops(#"[{"op": "add_example", "name": "Typical", "input": {"q": 1}}]"#), to: WorkflowDefinition())
        #expect(added.definition.examples.map(\.name) == ["Typical"])
        let removed = try WorkflowDraftPatcher.apply(
            try ops(#"[{"op": "add_example", "name": "Typical", "remove": true}]"#), to: added.definition)
        #expect(removed.definition.examples.isEmpty)
        #expect(throws: WorkflowDraftPatcher.Failure.self) {
            try WorkflowDraftPatcher.apply(
                try ops(#"[{"op": "add_example", "name": "Typical", "remove": true}]"#), to: removed.definition)
        }
    }

    @Test
    func parse_planPlaceholderTakesIdAndNameFromNode() throws {
        let op = try WorkflowDraftOp.parse(
            json(#"{"op": "plan_placeholder", "intent": "Read it", "node": {"id": "read", "name": "Read"}}"#))
        #expect(op == .planPlaceholder(id: "read", name: "Read", intent: "Read it"))
        let unexplained = try WorkflowDraftOp.parse(
            json(#"{"op": "plan_placeholder", "id": "read", "name": "Read the CSV"}"#))
        #expect(unexplained == .planPlaceholder(id: "read", name: "Read the CSV", intent: "Read the CSV"))
    }

    @Test
    func draftSchema_letsAMisplacedNodeInputReachTheOpParser() throws {
        let schema = try #require(WorkflowDraftTool().parameters)
        let args: [String: Any] = [
            "action": "patch", "ops": [["op": "update_node", "id": "a", "input": "{{input.x}}"]],
        ]
        #expect(SchemaValidator.validate(arguments: args, against: schema).isValid)
        #expect(throws: WorkflowDraftOp.ParseError.self) {
            try WorkflowDraftOp.parse(json(#"{"op": "add_example", "name": "A", "input": "hi"}"#))
        }
    }

    @Test
    func parse_updateNodeNamesKeysThatAreNotFields() {
        do {
            _ = try WorkflowDraftOp.parse(
                json(#"{"op": "update_node", "id": "a", "node": {"name": "x"}, "{": "update_node"}"#))
            Issue.record("expected a parse error")
        } catch let error as WorkflowDraftOp.ParseError {
            #expect(error.message.contains("not fields"), "\(error.message)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test
    func changingKind_dropsTheOldSpec() throws {
        let result = try WorkflowDraftPatcher.apply(
            try ops(
                #"""
                [{"op": "update_node", "id": "onboard", "node": {
                    "kind": "inference",
                    "inference": {"model_slot": "writer", "instructions": "Write a welcome", "mode": "generate"}
                }}]
                """#),
            to: WF.intake())
        guard case .inference(let spec) = result.definition.node("onboard")?.kind else {
            Issue.record("onboard should be an inference node")
            return
        }
        #expect(spec.modelSlot == "writer")
        guard case .object(let encoded) = WorkflowDraftPatcher.encode(result.definition.node("onboard")!) else {
            Issue.record("encode failed")
            return
        }
        #expect(encoded["code"] == nil)
    }

    @Test
    func addEdge_replacesTheSamePair() throws {
        let result = try WorkflowDraftPatcher.apply(
            try ops(#"[{"op": "add_edge", "from": "onboard", "to": "notify", "when": {"path": "welcome", "op": "exists"}}]"#),
            to: WF.intake())
        let edges = result.definition.edges.filter { $0.from == "onboard" && $0.to == "notify" }
        #expect(edges.count == 1)
        #expect(edges.first?.when?.path == "welcome")
    }

    @Test
    func diff_namesChangedFieldsAndEdges() {
        var changed = WF.intake()
        changed.nodes[0].name = "Sort"
        if case .inference(var spec) = changed.nodes[0].kind {
            spec.instructions = "New or existing?"
            changed.nodes[0].kind = .inference(spec)
        }
        changed.edges.removeAll { $0.from == "lookup" }
        changed.nodes.append(WF.code("audit"))
        let lines = WorkflowDiff.changes(from: WF.intake(), to: changed).map(\.line)
        #expect(lines.contains("Added node audit"))
        #expect(lines.contains { $0.hasPrefix("Removed edge lookup") })
        let classify = lines.first { $0.hasPrefix("Changed node classify") }
        #expect(classify?.contains("name") == true)
        #expect(classify?.contains("inference.instructions") == true)
        #expect(WorkflowDiff.changes(from: WF.intake(), to: WF.intake()).isEmpty)
    }

    @Test
    func draftUndo_restoresThePreviousDefinition() {
        var draft = WorkflowDraft(name: "A", definition: WF.intake())
        draft.edit(source: .user, summary: "Removed notify") { $0.definition.nodes.removeLast() }
        #expect(draft.definition.node("notify") == nil)
        let undone = draft.undo()
        #expect(undone?.summary == "Removed notify")
        #expect(draft.definition == WF.intake())
        #expect(draft.undo() == nil)
    }

    /// Review #12: a snapshot holds everything a save reads, so undoing a
    /// rebase puts the older definition back under its own base version.
    @Test
    func draftUndo_restoresBaseVersionSummaryAndHintsWithTheDefinition() throws {
        let templateID = UUID()
        var draft = WorkflowDraft(name: "A", summary: "v1 summary", templateID: templateID, baseVersion: 1, definition: WF.intake())
        draft.serverHints = [MCPServerHint(name: "Linear")]
        draft.bindings.models["decision"] = "foundation"

        draft.edit(source: .user, summary: "Loaded saved version 2") {
            $0.definition.nodes.removeLast()
            $0.summary = "v2 summary"
            $0.baseVersion = 2
            $0.serverHints = []
        }
        // A binding chosen after the edit is the user's and survives undo.
        draft.bindings.models["decision"] = "local/other"

        let popped = draft.undo()
        let undone = try #require(popped)
        #expect(undone.recordsIdentity && undone.baseVersion == 1 && undone.templateID == templateID)
        #expect(draft.definition == WF.intake())
        #expect(draft.baseVersion == 1)
        #expect(draft.templateID == templateID)
        #expect(draft.summary == "v1 summary")
        #expect(draft.serverHints.map(\.name) == ["Linear"])
        #expect(draft.bindings.models["decision"] == "local/other")

        // History written before these fields existed leaves them alone.
        var legacy = WorkflowDraft(name: "B", templateID: templateID, baseVersion: 3, definition: WF.intake())
        legacy.history = [WorkflowDraftEdit(source: .user, summary: "old", name: "B", definition: WorkflowDefinition())]
        legacy.undo()
        #expect(legacy.definition == WorkflowDefinition())
        #expect(legacy.baseVersion == 3 && legacy.templateID == templateID)
    }

    @Test
    func draftEdit_roundTripsThroughJSONWithOlderHistory() throws {
        var draft = WorkflowDraft(name: "A", templateID: UUID(), baseVersion: 1, definition: WF.intake())
        draft.edit(source: .architect, summary: "x") { $0.baseVersion = 2 }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkflowDraft.self, from: try encoder.encode(draft))
        #expect(decoded.history.last?.baseVersion == 1)
        #expect(decoded.history.last?.recordsIdentity == true)

        // An entry saved by an older build has only name + definition.
        let old = #"{"at":"2026-01-01T00:00:00Z","source":"user","summary":"s","name":"N","definition":{}}"#
        let entry = try decoder.decode(WorkflowDraftEdit.self, from: Data(old.utf8))
        #expect(entry.recordsIdentity == false && entry.bindings == nil && entry.serverHints == nil)
    }
}

@Suite(.serialized)
@MainActor
struct WorkflowDraftStoreTests {

    @Test
    func userEdits_reachTheNextTurnOnce() throws {
        let store = WorkflowDraftStore.shared
        let session = "architect-\(UUID().uuidString)"
        let draft = store.create(sessionID: session, from: WF.template(WF.intake()))
        defer { store.delete(draft.id) }
        #expect(store.takeTurnContext(sessionID: session) == nil)

        store.applyUserEdit(draft.id) { $0.definition.nodes.removeAll { $0.id == "notify" } }
        store.select(nodeID: "classify", in: draft.id)
        let context = try #require(store.takeTurnContext(sessionID: session))
        #expect(context.contains("Since your last turn"))
        #expect(context.contains("Removed node notify"))
        #expect(context.contains("`classify` selected"))

        let again = try #require(store.takeTurnContext(sessionID: session))
        #expect(!again.contains("Since your last turn"))
    }

    @Test
    func architectPatch_highlightsTouchedNodes_andUndoIsReported() throws {
        let store = WorkflowDraftStore.shared
        let session = "architect-\(UUID().uuidString)"
        let draft = store.create(sessionID: session)
        defer { store.delete(draft.id) }
        try store.applyArchitectPatch(
            draft.id, ops: try ops(#"[{"op": "plan_placeholder", "id": "a", "intent": "Do a"}]"#))
        #expect(store.draft(id: draft.id)?.lastPatchedNodeIDs == ["a"])
        #expect(store.draft(id: draft.id)?.pendingUserEdits.isEmpty == true)

        store.undo(draft.id)
        #expect(store.draft(id: draft.id)?.definition.nodes.isEmpty == true)
        let context = try #require(store.takeTurnContext(sessionID: session))
        #expect(context.contains("Undid: Added node a"))
    }

    @Test
    func draftWrites_landOnDisk_andADeleteWinsOverAPendingWrite() async throws {
        try await StoragePathsTestLock.shared.run { @MainActor in
            let root = WF.tempDir()
            OsaurusPaths.overrideRoot = root
            let store = WorkflowDraftStore.shared
            store.reload()
            defer {
                OsaurusPaths.overrideRoot = nil
                store.reload()
                try? FileManager.default.removeItem(at: root)
            }
            let draft = store.create(sessionID: "architect-\(UUID().uuidString)")
            try store.applyArchitectPatch(
                draft.id, ops: try ops(#"[{"op": "plan_placeholder", "id": "a", "intent": "Do a"}]"#))
            WorkflowDraftStore.flushPendingWrites()
            let url = WorkflowDraftStore.fileURL(draft.id)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let saved = try decoder.decode(WorkflowDraft.self, from: Data(contentsOf: url))
            #expect(saved.definition.nodes.map(\.id) == ["a"])

            store.reload()
            #expect(store.draft(id: draft.id)?.definition.nodes.map(\.id) == ["a"])

            store.applyUserEdit(draft.id) { $0.name = "Renamed" }
            store.delete(draft.id)
            WorkflowDraftStore.flushPendingWrites()
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test
    func architectPatch_onALongDraftWithFullHistory_staysCheap() async throws {
        try await StoragePathsTestLock.shared.run { @MainActor in
            let root = WF.tempDir()
            OsaurusPaths.overrideRoot = root
            let store = WorkflowDraftStore.shared
            store.reload()
            defer {
                OsaurusPaths.overrideRoot = nil
                store.reload()
                try? FileManager.default.removeItem(at: root)
            }
            let prompt = String(repeating: "Summarize the client's situation carefully. ", count: 230)
            let nodes = (0..<10).map { index in
                WorkflowNode(
                    id: "n\(index)", name: "Step \(index)",
                    kind: .inference(InferenceSpec(modelSlot: "writer", instructions: prompt)))
            }
            let def = WorkflowDefinition(inputSchema: WF.object([:]), outputSchema: WF.object([:]), nodes: nodes)
            let draft = store.create(sessionID: "architect-\(UUID().uuidString)", from: WF.template(def))
            defer { store.delete(draft.id) }
            @MainActor func rename(_ i: Int) throws {
                try store.applyArchitectPatch(
                    draft.id,
                    ops: try ops(#"[{"op": "update_node", "id": "n\#(i % 10)", "node": {"name": "Step v\#(i)"}}]"#))
            }
            for i in 0..<WorkflowDraft.historyLimit { try rename(i) }
            #expect(store.draft(id: draft.id)?.history.count == WorkflowDraft.historyLimit)

            let clock = ContinuousClock()
            let elapsed = try clock.measure {
                for i in 0..<20 { try rename(WorkflowDraft.historyLimit + i) }
            }
            WorkflowDraftStore.flushPendingWrites()
            #expect(elapsed < .seconds(1), "20 patches on the main actor took \(elapsed)")
        }
    }

    @Test
    func failedPatch_isNotRecorded() throws {
        let store = WorkflowDraftStore.shared
        let draft = store.create(sessionID: "architect-\(UUID().uuidString)", from: WF.template(WF.intake()))
        defer { store.delete(draft.id) }
        #expect(throws: WorkflowDraftPatcher.Failure.self) {
            try store.applyArchitectPatch(draft.id, ops: try ops(#"[{"op": "remove_node", "id": "nope"}]"#))
        }
        #expect(store.draft(id: draft.id)?.history.isEmpty == true)
    }

    @Test
    func testAnswersStayWithTheDraft_neverReachTheInstall_andGoWithTheDraft() async throws {
        try await StoragePathsTestLock.shared.run { @MainActor in
            let root = WF.tempDir()
            OsaurusPaths.overrideRoot = root
            let store = WorkflowDraftStore.shared
            let answers = SavedAnswersStore.shared
            store.reload()
            TemplateStore.shared.reload()
            InstalledWorkflowStore.shared.reload()
            answers.resetForTesting()
            defer {
                OsaurusPaths.overrideRoot = nil
                InstalledWorkflowStore.shared.resetForTesting()
                answers.resetForTesting()
                store.reload()
                TemplateStore.shared.reload()
                try? FileManager.default.removeItem(at: root)
            }
            let draft = store.create(sessionID: "architect-\(UUID().uuidString)", from: WF.template(WF.intake()))
            let field = DialogField(key: "firm", label: "Firm", persistence: .remember)
            answers.save(workflowID: draft.id, nodeID: "ask", field: field, value: .string("Acme"))

            // The person's own untested save; the gate itself is covered in WorkflowTrustSurfaceTests.
            let installed = try WorkflowDraftSaver.save(draftID: draft.id, changelog: "First", requireEvidence: false)
            #expect(answers.value(workflowID: installed.id, nodeID: "ask", fieldKey: "firm") == nil)
            #expect(answers.value(workflowID: draft.id, nodeID: "ask", fieldKey: "firm") == .string("Acme"))

            store.delete(draft.id)
            #expect(answers.value(workflowID: draft.id, nodeID: "ask", fieldKey: "firm") == nil)
        }
    }

    @Test
    func draftsPersistToDisk() throws {
        let store = WorkflowDraftStore.shared
        let draft = store.create(sessionID: "architect-\(UUID().uuidString)", from: WF.template(WF.intake()))
        defer { store.delete(draft.id) }
        store.applyUserEdit(draft.id) { $0.name = "Renamed" }
        store.reload()
        #expect(store.draft(id: draft.id)?.name == "Renamed")
        #expect(store.draft(id: draft.id)?.definition == WF.intake())
    }

    @Test
    func architectDetach_makesAnOpenedWorkflowANewOne_andNamesWhatItEdited() throws {
        let store = WorkflowDraftStore.shared
        let session = "architect-\(UUID().uuidString)"
        let template = WF.template(WF.intake())
        let draft = store.create(sessionID: session, from: template)
        defer { store.delete(draft.id) }
        #expect(DraftEditing(draft)?.label(draftName: draft.name) == "Editing v\(template.version)")
        #expect(WorkflowDraftTool.describe(draft)["editing"] != nil)

        try store.applyArchitectPatch(
            draft.id, ops: try ops(#"[{"op": "detach"}, {"op": "remove_node", "id": "notify"}]"#))
        let after = try #require(store.draft(forSession: session))
        #expect(after.id == draft.id)
        #expect(after.templateID == nil && after.baseVersion == nil)
        #expect(DraftEditing(after) == nil)
        #expect(WorkflowDraftTool.describe(after)["editing"] == nil)
        #expect(after.template().id == draft.id)
        #expect(after.history.last?.summary.hasPrefix("Made it a new workflow") == true)
    }

    @Test
    func detach_afterTheFirstSave_movesToANewIDSoTheSavedWorkflowStaysAsItIs() async throws {
        try await StoragePathsTestLock.shared.run { @MainActor in
            let root = WF.tempDir()
            OsaurusPaths.overrideRoot = root
            let store = WorkflowDraftStore.shared
            store.reload()
            TemplateStore.shared.reload()
            defer {
                OsaurusPaths.overrideRoot = nil
                store.reload()
                TemplateStore.shared.reload()
                try? FileManager.default.removeItem(at: root)
            }
            let session = "architect-\(UUID().uuidString)"
            let draft = store.create(sessionID: session)
            store.applyUserEdit(draft.id) {
                $0.name = "Notes"
                $0.definition = WF.intake()
            }
            let saved = try TemplateStore.shared.save(try #require(store.draft(id: draft.id)).template())
            store.markSaved(draft.id, template: saved)
            #expect(saved.id == draft.id)
            store.applyUserEdit(draft.id) { $0.name = "Download videos" }
            let renamed = try #require(store.draft(id: draft.id))
            #expect(DraftEditing(renamed)?.label(draftName: renamed.name) == "Editing Notes v1")

            store.detach(draft.id)
            let moved = try #require(store.draft(forSession: session))
            #expect(moved.id != draft.id)
            #expect(store.draft(id: draft.id) == nil)
            #expect(moved.templateID == nil && moved.baseVersion == nil)
            #expect(moved.template().id != saved.id)
            #expect(moved.definition == WF.intake())
            #expect(moved.history.map(\.definition) == renamed.history.map(\.definition))
            #expect(moved.history.allSatisfy { $0.templateID == nil && $0.baseVersion == nil }, "history forgets the saved workflow")
            #expect(moved.pendingUserEdits.last?.contains("saving no longer changes \"Notes\"") == true)

            // Undo past the detach keeps it detached: the saved workflow is
            // reopened from Workflows, not by undoing.
            store.undo(moved.id)
            let undone = try #require(store.draft(id: moved.id))
            #expect(undone.templateID == nil && undone.baseVersion == nil)
            #expect(undone.name == "Notes")
        }
    }

    /// Review #12: undoing a rebase restores the base version the draft
    /// held, so the next save continues the right version.
    @Test
    func undoPastARebase_restoresTheOlderBaseVersion() throws {
        let store = WorkflowDraftStore.shared
        let session = "architect-\(UUID().uuidString)"
        let v1 = WF.template(WF.intake())
        let draft = store.create(sessionID: session, from: v1)
        defer { store.delete(draft.id) }

        var v2 = v1
        v2.version = 2
        v2.name = "Client Intake v2"
        v2.payload = .workflow(WF.intake().with { $0.nodes.removeLast() })
        store.rebase(draft.id, onto: v2)
        let rebased = try #require(store.draft(id: draft.id))
        #expect(rebased.baseVersion == 2 && rebased.name == "Client Intake v2")
        #expect(rebased.definition.node("notify") == nil)

        store.undo(draft.id)
        let restored = try #require(store.draft(id: draft.id))
        #expect(restored.baseVersion == 1)
        #expect(restored.templateID == v1.id)
        #expect(restored.name == v1.name)
        #expect(restored.definition == WF.intake())
        #expect(restored.template().version == 1)
    }

    /// Review #12: an Architect `detach` op is not undone into a rebind.
    @Test
    func undoPastAnArchitectDetach_staysDetached() throws {
        let store = WorkflowDraftStore.shared
        let session = "architect-\(UUID().uuidString)"
        let draft = store.create(sessionID: session, from: WF.template(WF.intake()))
        defer { store.delete(draft.id) }
        try store.applyArchitectPatch(
            draft.id, ops: try ops(#"[{"op": "detach"}, {"op": "remove_node", "id": "notify"}]"#))
        store.undo(draft.id)
        let after = try #require(store.draft(id: draft.id))
        #expect(after.definition == WF.intake(), "the node edit is undone")
        #expect(after.templateID == nil && after.baseVersion == nil, "but it stays a new workflow")
    }

    /// Review #13: test-run fallbacks are per run; the draft's bindings
    /// stay what the user chose, and that is what Save installs.
    @Test
    func testBindings_completeTheRunWithoutWritingToTheDraft() throws {
        let store = WorkflowDraftStore.shared
        var def = WF.intake()
        def.nodes[3] = WorkflowNode(
            id: "notify", name: "Notify",
            kind: .code(CodeSpec(source: "async function run(input, ctx) { return {} }", secrets: ["API_KEY"])),
            input: .object([:]), outputSchema: WF.object([:]))
        let draft = store.create(sessionID: "architect-\(UUID().uuidString)", from: WF.template(def))
        defer { store.delete(draft.id) }
        #expect(store.draft(id: draft.id)?.bindings == InstallBindings())

        let forRun = store.testBindings(draft.id)
        #expect(forRun.secrets["API_KEY"] == WorkflowSecretsKeychain.secretAccount(scope: draft.id, key: "API_KEY"))
        #expect(store.draft(id: draft.id)?.bindings == InstallBindings(), "nothing written back")

        var env = SetupChecker.Environment(
            registeredToolNames: [],
            modelCatalog: ConfigModelReference.Catalog(localModelIds: ["foundation"], providers: []),
            isPermissionGranted: { _ in true }, bookmarkResolves: { _ in true }, knowledgeCollectionExists: { _ in true })
        env.defaultModel = "foundation"
        let completed = WorkflowDraftStore.completedForTest(try #require(store.draft(id: draft.id)), environment: env)
        #expect(completed.models["decision"] == "foundation", "an unbound slot takes the default for the run")

        store.setBindings(draft.id, InstallBindings(models: ["decision": "foundation"]))
        #expect(store.testBindings(draft.id).models["decision"] == "foundation")
        #expect(store.draft(id: draft.id)?.bindings.models == ["decision": "foundation"])
    }
}

extension WorkflowDefinition {
    fileprivate func with(_ change: (inout WorkflowDefinition) -> Void) -> WorkflowDefinition {
        var copy = self
        change(&copy)
        return copy
    }
}

@Suite(.serialized)
@MainActor
struct ArchitectToolGateTests {

    @Test
    func draftTools_refuseOtherAgents() async throws {
        for agent in [Agent.defaultId, UUID()] {
            for tool: OsaurusTool in [
                WorkflowDraftTool(), WorkflowTestTool(), WorkflowProposeSaveTool(),
            ] {
                let result = try await ChatExecutionContext.$currentAgentId.withValue(agent) {
                    try await tool.execute(argumentsJSON: "{}")
                }
                #expect(result.contains("only available to the Architect"), "\(tool.name) leaked to \(agent)")
            }
        }
    }

    @Test
    func handoff_isDefaultAgentOnly() async throws {
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            try await ArchitectHandoffTool().execute(argumentsJSON: #"{"brief": "x"}"#)
        }
        #expect(result.contains("\"ok\":false") || result.contains("\"ok\": false"))
    }

    @Test
    func draftGet_createsTheChatsDraft() async throws {
        let session = "architect-\(UUID().uuidString)"
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            try await ChatExecutionContext.$currentSessionId.withValue(session) {
                try await WorkflowDraftTool().execute(argumentsJSON: #"{"action": "get"}"#)
            }
        }
        let draft = try #require(WorkflowDraftStore.shared.draft(forSession: session))
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        #expect(result.contains(draft.id.uuidString) || result.contains("definition"))
    }

    @Test
    func draftTools_listsStepToolsWithoutTheExcludedOnes() async throws {
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            try await WorkflowDraftTool().execute(argumentsJSON: #"{"action": "tools"}"#)
        }
        let names = WorkflowToolCatalog.entries().map(\.name)
        #expect(names.contains("file_write"), "folder tools are listed before any folder is open")
        for excluded in ["run_workflow", "todo", "complete", "capabilities_load", "spawn_agent"] {
            #expect(!names.contains(excluded))
        }
        #expect(result.contains("\"file_write\""), "\(result.prefix(400))")
        #expect(!result.contains("\"run_workflow\""))
        #expect(!result.contains("\"parameters\""), "the unfiltered list is names and summaries only")

        let filtered = try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            try await WorkflowDraftTool().execute(argumentsJSON: #"{"action": "tools", "query": "file_wr"}"#)
        }
        #expect(filtered.contains("\"file_write\""))
        #expect(filtered.contains("\"parameters\""))
        #expect(!filtered.contains("\"shell_run\""))

        // Words match separately, like a model's "write file markdown create".
        let ranked = WorkflowToolCatalog.entries(query: "write file markdown create").prefix(WorkflowDraftTool.toolMatchLimit)
        #expect(ranked.contains { $0.name == "file_write" }, "\(ranked.map(\.name))")
        #expect(WorkflowToolCatalog.status(of: "no_such_tool_\(UUID().uuidString)") == L("Not on this Mac"))
    }

    @Test
    func testingADraftThatNeedsSetup_opensTheWizardInsteadOfRunning() async throws {
        let session = "architect-\(UUID().uuidString)"
        let node = WorkflowNode(
            id: "send", name: "Send",
            kind: .code(CodeSpec(source: "async function run(input, ctx) { return {} }", secrets: ["WF_GATE_KEY"])),
            input: .object([:]), outputSchema: WF.object([:]))
        let store = WorkflowDraftStore.shared
        let draft = store.create(sessionID: session, from: WF.template(WorkflowDefinition(nodes: [node])))
        defer {
            store.delete(draft.id)
            store.setupRequest = nil
        }
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            try await ChatExecutionContext.$currentSessionId.withValue(session) {
                try await WorkflowTestTool().execute(argumentsJSON: #"{"input": {}}"#)
            }
        }
        #expect(result.contains("needs_setup"), "\(result)")
        #expect(result.contains("WF_GATE_KEY"), "\(result)")
        #expect(store.setupRequest == draft.id)
        #expect(store.draft(id: draft.id)?.testRunIDs.isEmpty == true, "nothing ran")
    }

    @Test
    func freshState_givesATestTheFirstRunsView() async throws {
        let session = "architect-\(UUID().uuidString)"
        let def = WorkflowDefinition(
            inputSchema: WF.object([:]), outputSchema: WF.object([:]),
            nodes: [WorkflowNode(id: "count", name: "Count", kind: .state(StateSpec(action: .increment, key: "n")))],
            output: .object([:]))
        let store = WorkflowDraftStore.shared
        let draft = store.create(sessionID: session, from: WF.template(def))
        defer {
            WorkflowStateStore.shared.deleteAll(workflow: draft.id)
            store.delete(draft.id)
        }
        // What earlier test runs left in the draft's store.
        _ = try WorkflowStateStore.shared.increment(workflow: draft.id, table: "vars", key: "n", by: 4)
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            try await ChatExecutionContext.$currentSessionId.withValue(session) {
                try await WorkflowTestTool().execute(argumentsJSON: #"{"input": {}, "fresh_state": true}"#)
            }
        }
        let object = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        let nodes = (object?["result"] as? [String: Any])?["nodes"] as? [[String: Any]]
        #expect((nodes?.first?["output"] as? [String: Any])?["value"] as? Double == 1, "\(result)")
    }

    @Test
    func inferenceWithoutASlot_usesTheMainSlot() throws {
        let ops = try [
            JSONValue.object([
                "op": .string("plan_placeholder"), "id": .string("a"), "name": .string("A"), "intent": .string("Say hi"),
            ]),
            .object([
                "op": .string("update_node"), "id": .string("a"),
                "node": .object([
                    "kind": .string("inference"), "inference": .object(["instructions": .string("Say hi")]),
                ]),
            ]),
        ].map(WorkflowDraftOp.parse)
        let def = try WorkflowDraftPatcher.apply(ops, to: WorkflowDefinition()).definition
        guard case .inference(let spec)? = def.node("a")?.kind else {
            Issue.record("not an inference node")
            return
        }
        #expect(spec.modelSlot == InferenceSpec.defaultSlot)
    }

    @Test
    func thePanelsTestRun_refusesLikeTheTool() throws {
        let store = WorkflowDraftStore.shared
        let planned = store.create(
            sessionID: "architect-\(UUID().uuidString)",
            from: WF.template(WorkflowDefinition(nodes: [WorkflowNode(id: "a", name: "A", intent: "Do A", kind: nil)])))
        let secret = WorkflowNode(
            id: "send", name: "Send",
            kind: .code(CodeSpec(source: "async function run(input, ctx) { return {} }", secrets: ["WF_PANEL_KEY"])),
            input: .object([:]), outputSchema: WF.object([:]))
        let gated = store.create(
            sessionID: "architect-\(UUID().uuidString)", from: WF.template(WorkflowDefinition(nodes: [secret])))
        defer {
            store.delete(planned.id)
            store.delete(gated.id)
            store.setupRequest = nil
        }

        guard case .failure(.invalid(let issues)) = WorkflowDraftTester.startFromPanel(
            draftID: planned.id, input: .object([:]), sessionID: nil)
        else { Issue.record("a planned step can't run"); return }
        #expect(!issues.isEmpty)

        guard case .failure(.needsSetup(let blocking)) = WorkflowDraftTester.startFromPanel(
            draftID: gated.id, input: .object([:]), sessionID: nil)
        else { Issue.record("a missing secret blocks the run"); return }
        #expect(blocking.contains { $0.value.contains("WF_PANEL_KEY") })
        #expect(store.setupRequest == gated.id, "the setup wizard opens")
        #expect(store.draft(id: gated.id)?.testRunIDs.isEmpty == true, "nothing ran")
    }

    @Test
    func theDraftStatus_followsTheDraftAndItsLatestTest() throws {
        let store = WorkflowDraftStore.shared
        let empty = store.create(sessionID: "architect-\(UUID().uuidString)")
        let node = WorkflowNode(
            id: "shape", name: "Shape",
            kind: .code(CodeSpec(source: "async function run(input, ctx) { return {} }")),
            input: .object([:]), outputSchema: WF.object([:]))
        var ready = store.create(
            sessionID: "architect-\(UUID().uuidString)", from: WF.template(WorkflowDefinition(nodes: [node])))
        defer {
            store.delete(empty.id)
            store.delete(ready.id)
        }
        store.applyUserEdit(ready.id) { $0.name = "Shaper" }
        ready = try #require(store.draft(id: ready.id))

        let blank = DraftStatus(draft: empty, latest: nil)
        #expect(blank.kind == .drafting)
        #expect(!blank.canSave)

        #expect(DraftStatus(draft: ready, latest: nil).kind == .ready)
        #expect(DraftStatus(draft: ready, latest: nil).canSave)

        func run(_ status: WorkflowRunStatus, at date: Date) -> WorkflowRun {
            var run = WorkflowRun(
                workflowID: ready.id, workflowName: ready.name, templateID: ready.id, templateVersion: 1,
                caller: WorkflowCaller(kind: .test), input: .object([:]), nodeIDs: ["shape"], startedAt: date)
            run.status = status
            return run
        }
        #expect(DraftStatus(draft: ready, latest: run(.running, at: Date())).kind == .testing)
        #expect(DraftStatus(draft: ready, latest: run(.completed, at: Date())).kind == .tested)
        #expect(DraftStatus(draft: ready, latest: run(.failed, at: Date())).kind == .testFailed)
        #expect(
            DraftStatus(draft: ready, latest: run(.completed, at: .distantPast)).kind == .ready,
            "a test from before the last edit no longer counts")
    }

    @Test
    func undo_namesTheStepsTheLastEditTouched() throws {
        let store = WorkflowDraftStore.shared
        let node = WorkflowNode(
            id: "shape", name: "Shape",
            kind: .code(CodeSpec(source: "async function run(input, ctx) { return {} }")),
            input: .object([:]), outputSchema: WF.object([:]))
        let created = store.create(
            sessionID: "architect-\(UUID().uuidString)", from: WF.template(WorkflowDefinition(nodes: [node])))
        defer { store.delete(created.id) }
        #expect(WorkflowStepActions.undoTitle(created) == nil)

        store.applyUserEdit(created.id) { $0.name = "Shaper" }
        #expect(WorkflowStepActions.undoTitle(try #require(store.draft(id: created.id))) == "Undo Rename")

        store.applyUserEdit(created.id) { $0.definition.nodes[0].name = "Tidy up" }
        #expect(
            WorkflowStepActions.undoTitle(try #require(store.draft(id: created.id))) == "Undo Your Change to Tidy up")

        _ = try store.applyArchitectPatch(
            created.id, ops: [.updateNode(id: "shape", fields: ["name": .string("Clean")])])
        let title = WorkflowStepActions.undoTitle(try #require(store.draft(id: created.id)))
        #expect(title == "Undo the Architect's Change to Clean", "\(title ?? "nil")")
        #expect(title?.contains("inference.") == false)
    }

    @Test
    func aPanelTestsOutcome_reachesTheArchitect() {
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "X", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .test), input: .object([:]), nodeIDs: ["a"])
        run.status = .failed
        run.error = WorkflowRunError(nodeID: "a", reason: "boom")
        let line = WorkflowDraftTester.outcomeLine(run)
        #expect(line.contains("failed"))
        #expect(line.contains("[a] boom"))
        #expect(line.contains(run.id.uuidString))
    }

    @Test
    func patchThroughTheTool_isAtomic() async throws {
        let session = "architect-\(UUID().uuidString)"
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            try await ChatExecutionContext.$currentSessionId.withValue(session) {
                try await WorkflowDraftTool().execute(
                    argumentsJSON: #"""
                    {"action": "patch", "ops": [
                      {"op": "plan_placeholder", "id": "a", "intent": "A"},
                      {"op": "add_edge", "from": "a", "to": "b"}
                    ]}
                    """#)
            }
        }
        let draft = try #require(WorkflowDraftStore.shared.draft(forSession: session))
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        #expect(result.contains("No node `b`"))
        #expect(draft.definition.nodes.isEmpty)
    }

    /// A harness turn only streams the call's name, so the proposal waits on
    /// the store for the chat to raise the Save card once.
    @Test
    func harnessSaveProposal_isTakenOnceByItsChat() {
        let store = WorkflowDraftStore.shared
        let session = UUID().uuidString
        let draft = store.create(sessionID: session)
        defer { store.delete(draft.id) }
        let proposal = WorkflowDraftStore.SaveProposal(
            draftID: draft.id, name: "Digest", version: 2, changelog: "Adds a summary", updates: nil)
        store.recordSaveProposal(proposal)

        #expect(store.takeSaveProposal(sessionID: UUID().uuidString) == nil, "another chat's turn")
        #expect(store.takeSaveProposal(sessionID: session) == proposal)
        #expect(store.takeSaveProposal(sessionID: session) == nil)
    }

    @Test
    func proposeSave_needsAValidNamedDraft() async throws {
        let session = "architect-\(UUID().uuidString)"
        let draft = WorkflowDraftStore.shared.create(sessionID: session)
        defer { WorkflowDraftStore.shared.delete(draft.id) }
        let result = try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            try await ChatExecutionContext.$currentSessionId.withValue(session) {
                try await WorkflowProposeSaveTool().execute(argumentsJSON: #"{"changelog": "First version"}"#)
            }
        }
        #expect(!result.contains("waiting_for_user"))
        #expect(TemplateStore.shared.latest(id: draft.id) == nil)
    }
}

@Suite(.serialized)
@MainActor
struct ArchitectToolExposureTests {

    private static func snapshot(_ agentId: UUID) -> AgentConfigSnapshot {
        AgentConfigSnapshot(
            agentId: agentId, toolsDisabled: false, memoryDisabled: false, autonomousConfig: nil, toolMode: .auto,
            model: nil, manualToolNames: nil, systemPrompt: "", dbEnabled: false)
    }

    @Test
    func architect_getsExactlyItsSurface() {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let names = Set(
            SystemPromptComposer.resolveTools(snapshot: Self.snapshot(Agent.architectId), executionMode: .none)
                .map { $0.function.name })
        #expect(names.isSubset(of: ToolRegistry.architectAllowedToolNames))
        #expect(ToolRegistry.architectToolNames.isSubset(of: names))
        #expect(names.contains("osaurus_inspect"))
        #expect(!names.contains("osaurus_config"))
        #expect(!names.contains(ArchitectHandoffTool.toolName))
        #expect(!names.contains("todo") && !names.contains("complete"))
        #expect(!names.contains("workflow_validate"))
    }

    @Test
    func architect_inspectIsLimitedToModelsMCPAndPlugins() async throws {
        ConfigurationDomainBootstrap.registerBuiltIns()
        let tools = SystemPromptComposer.resolveTools(snapshot: Self.snapshot(Agent.architectId), executionMode: .none)
        let inspect = try #require(tools.first { $0.function.name == "osaurus_inspect" })
        let scopes = inspect.function.parameters?.objectValue?["properties"]?.objectValue?["scope"]?.objectValue?["enum"]?
            .arrayValue?.compactMap(\.stringValue)
        #expect(scopes == OsaurusInspectTool.architectScopes)

        let refused = try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            try await OsaurusInspectTool().execute(argumentsJSON: #"{"action": "list", "scope": "agents"}"#)
        }
        #expect(refused.contains("models, mcp, or plugins"))
        let status = try await ChatExecutionContext.$currentAgentId.withValue(Agent.architectId) {
            try await OsaurusInspectTool().execute(argumentsJSON: #"{"action": "status"}"#)
        }
        #expect(status.contains("models, mcp, or plugins"))
    }

    @Test
    func otherAgents_neverSeeDraftTools() {
        ConfigurationDomainBootstrap.registerBuiltIns()
        for agent in [Agent.defaultId, UUID()] {
            let names = Set(
                SystemPromptComposer.resolveTools(snapshot: Self.snapshot(agent), executionMode: .none)
                    .map { $0.function.name })
            #expect(names.isDisjoint(with: ToolRegistry.architectToolNames))
        }
        let defaultNames = Set(
            SystemPromptComposer.resolveTools(snapshot: Self.snapshot(Agent.defaultId), executionMode: .none)
                .map { $0.function.name })
        #expect(defaultNames.contains(ArchitectHandoffTool.toolName))
        let customNames = Set(
            SystemPromptComposer.resolveTools(snapshot: Self.snapshot(UUID()), executionMode: .none)
                .map { $0.function.name })
        #expect(!customNames.contains(ArchitectHandoffTool.toolName))
    }

    @Test
    func architect_isABuiltInWithItsOwnPrompt() {
        #expect(Agent.builtInAgents.map(\.id) == [Agent.defaultId, Agent.architectId])
        #expect(Agent.architect.isBuiltIn)
        #expect(AgentManager.resolvedAutonomousExec(for: .architect, availability: .available) == nil)
        #expect(SystemPromptComposer.PromptProfile.resolve(snapshot: Self.snapshot(Agent.architectId)) == .architect)
        let prompt = ArchitectSystemPromptBuilder.render()
        for tool in ToolRegistry.architectToolNames { #expect(prompt.contains(tool)) }
        #expect(prompt.contains("x-order"))
    }

    /// On Claude Code or Pi the Architect gets its persona, not the stock
    /// coding prompt, plus what its built-in loop would otherwise enforce.
    @Test
    func architectOnAHarness_getsThePersonaAndTheHarnessRules() {
        let prompt = HarnessTurnDriver.harnessSystemPrompt(for: Agent.architectId)
        #expect(prompt.hasPrefix(ArchitectSystemPromptBuilder.render().prefix(200)))
        #expect(prompt.hasSuffix(ArchitectSystemPromptBuilder.harnessAddendum))
        for tool in HarnessGrantStore.architectToolNames { #expect(ArchitectSystemPromptBuilder.harnessAddendum.contains(tool)) }
        #expect(!HarnessGrantStore.architectToolNames.contains("clarify"))
        #expect(!HarnessTurnDriver.harnessSystemPrompt(for: UUID()).contains("Running in an external harness"))
    }

    @Test
    func theArchitectGetsItsOwnStepBudget_andAUserSettingAboveItWins() {
        let budget = ArchitectConfiguration.stepBudget
        #expect(ArchitectConfiguration.maxToolAttempts(agentId: Agent.architectId, configured: 15) == budget)
        #expect(ArchitectConfiguration.maxToolAttempts(agentId: Agent.architectId, configured: budget + 20) == budget + 20)
        #expect(ArchitectConfiguration.maxToolAttempts(agentId: Agent.defaultId, configured: 15) == 15)
        #expect(ArchitectConfiguration.maxToolAttempts(agentId: nil, configured: 15) == 15)
        #expect(!ArchitectConfiguration.pausedMessage.contains("Max Tool Attempts"))
        #expect(!ArchitectConfiguration.outputLimitMessage.contains("Max Tokens"))
    }

    @Test
    func theArchitectStartsWithWorkflowIdeas_withStableIds() {
        let actions = Agent.architect.chatQuickActions ?? []
        #expect(actions.map(\.text).last == "Something else…")
        #expect(actions.count == 4)
        #expect(Agent.architect.chatQuickActions?.map(\.id) == actions.map(\.id))
    }
}

@Suite
@MainActor
struct DraftTestTabTests {

    @Test
    func inputSummary_listsEnteredFields_inFormOrder_hidingSecrets() {
        let fields = [
            DialogField(key: "url", label: "Channel URL"),
            DialogField(key: "token", label: "Token", type: .secret),
            DialogField(key: "notes", label: "Notes", required: false),
        ]
        let summary = ArchitectSidebarPanel.inputSummary(
            fields, values: ["url": .string(" https://youtube.com/@bob "), "token": .string("abc"), "notes": .string("")])
        #expect(summary == "Channel URL: https://youtube.com/@bob · Token: ••••")
        #expect(ArchitectSidebarPanel.inputSummary(fields, values: [:]) == "Nothing entered yet")
    }

    @Test
    func longSectionsScrollInABoxOfMostOfTheList() {
        #expect(DraftSectionList<ArchitectSidebarPanel.TestPanel>.boundedHeight(listHeight: 600) == 360)
        #expect(DraftSectionList<ArchitectSidebarPanel.TestPanel>.boundedHeight(listHeight: 240) == 200)
    }

    @Test
    func aFinishedTestOpensItsResult_otherwiseItsSteps() {
        let def = WorkflowDefinition(nodes: [
            WorkflowNode(id: "ask", name: "Ask", intent: "a", kind: nil),
            WorkflowNode(id: "fetch", name: "Download", intent: "b", kind: nil),
        ])
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "X", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .test), input: .object([:]), nodeIDs: ["ask", "fetch"])
        run.status = .running
        #expect(ArchitectSidebarPanel.panel(after: run) == .progress)
        run.nodes[0].status = .done
        #expect(ArchitectSidebarPanel.progressSummary(run, definition: def).hasSuffix("1 of 2 steps"))
        run.nodes[1].status = .failed
        run.status = .failed
        #expect(ArchitectSidebarPanel.panel(after: run) == .progress)
        #expect(ArchitectSidebarPanel.progressSummary(run, definition: def).hasSuffix("failed at Download"))
        run.status = .completed
        run.output = .object(["count": .number(3)])
        #expect(ArchitectSidebarPanel.panel(after: run) == .result)
    }
}
