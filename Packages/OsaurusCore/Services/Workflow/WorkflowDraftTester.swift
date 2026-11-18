//
//  WorkflowDraftTester.swift
//  osaurus
//
//  Starts a test run of an Architect draft. The Architect's `workflow_test`
//  and the Draft panel's Test Run share it, so both refuse the same invalid
//  or not-yet-set-up drafts and both record the run on the draft.
//

import Foundation

@MainActor
enum WorkflowDraftTester {
    enum Refusal: Error, Equatable {
        case missingDraft
        case invalid([WorkflowIssue])
        /// Opens the setup wizard in the Draft panel.
        case needsSetup([SetupItem])
    }

    static func start(
        draftID: UUID, input: JSONValue, startAt: String? = nil, pinned: [String: JSONValue] = [:],
        reusing: WorkflowRun? = nil, sessionID: String?
    ) -> Result<UUID, Refusal> {
        let drafts = WorkflowDraftStore.shared
        guard let draft = drafts.draft(id: draftID) else { return .failure(.missingDraft) }
        let issues = WorkflowValidator.validate(draft.definition, allowPlaceholders: false)
        guard issues.isEmpty else { return .failure(.invalid(issues)) }
        let bindings = drafts.testBindings(draft.id)
        let report = SetupChecker.check(draft.template(), bindings: bindings, subjectId: draft.id, agentsByName: true)
        if report.hasBlockers {
            drafts.setupRequest = draft.id
            return .failure(.needsSetup(report.blocking))
        }
        let runID = WorkflowRunService.shared.startTest(
            draftID: draft.id, template: draft.template(), bindings: bindings, input: input,
            startAt: startAt, pinned: pinned, reusing: reusing, sessionID: sessionID)
        drafts.recordTestRun(draft.id, runID: runID)
        return .success(runID)
    }

    /// How to test from `nodeID` reusing `run`: its input, and the results
    /// of every step before `nodeID`, each of which must have finished in
    /// that run and be unchanged since (same definition, same input).
    struct ReusePlan: Equatable {
        var input: JSONValue
        var startAt: String
        var pinned: [String: JSONValue]
        var reused: [String]
    }

    enum ReuseRefusal: Error, Equatable {
        case unknownStep(String)
        /// Steps before `nodeID` that did not finish in that run.
        case unfinished([String])
        /// Steps before `nodeID` that changed since that run.
        case changed([String])
        /// Steps before `nodeID` whose files from that run are gone.
        case missingFiles([String])

        var message: String {
            switch self {
            case .unknownStep(let id): return L("The draft has no step \"\(id)\".")
            case .unfinished(let ids):
                return L("These earlier steps have no result to reuse from the last test: \(ids.joined(separator: ", ")). Run the whole test first.")
            case .changed(let ids):
                return L("These earlier steps changed since the last test, so their results can't be reused: \(ids.joined(separator: ", ")). Test from the first of them, or run the whole test.")
            case .missingFiles(let ids):
                return L("Files these earlier steps made in the last test are gone: \(ids.joined(separator: ", ")). Run the whole test again.")
            }
        }
    }

    nonisolated static func reusePlan(from run: WorkflowRun, nodeID: String, definition: WorkflowDefinition) -> Result<
        ReusePlan, ReuseRefusal
    > {
        guard definition.node(nodeID) != nil else { return .failure(.unknownStep(nodeID)) }
        let ancestors = (WorkflowValidator.ancestorMap(definition)[nodeID] ?? []).sorted()
        var pinned: [String: JSONValue] = [:]
        var unfinished: [String] = []
        var changed: [String] = []
        var missingFiles: [String] = []
        for id in ancestors {
            guard let node = definition.node(id), let earlier = run.node(id),
                earlier.status == .done || earlier.status == .pinned, let output = earlier.output
            else {
                unfinished.append(id)
                continue
            }
            guard let hash = earlier.specHash, node.specHash(input: earlier.input ?? .object([:])) == hash else {
                changed.append(id)
                continue
            }
            let files = run.artifacts.filter { $0.nodeID == id && $0.source != .output && $0.isAvailable }
            if files.contains(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
                missingFiles.append(id)
                continue
            }
            pinned[id] = output
        }
        let order = WorkflowValidator.topologicalOrder(definition) ?? ancestors
        if !unfinished.isEmpty { return .failure(.unfinished(unfinished)) }
        if !changed.isEmpty { return .failure(.changed(order.filter(changed.contains))) }
        if !missingFiles.isEmpty { return .failure(.missingFiles(order.filter(missingFiles.contains))) }
        return .success(ReusePlan(input: run.input, startAt: nodeID, pinned: pinned, reused: ancestors))
    }

    /// Test from `nodeID` with the latest test's results for the steps
    /// before it (the Draft panel's Test From This Step).
    struct StepTestRefusal: Error, Equatable {
        var message: String
    }

    static func startFromStep(draftID: UUID, nodeID: String, sessionID: String?) -> Result<UUID, StepTestRefusal> {
        let drafts = WorkflowDraftStore.shared
        func refuse(_ message: String) -> Result<UUID, StepTestRefusal> { .failure(StepTestRefusal(message: message)) }
        guard let draft = drafts.draft(id: draftID) else { return refuse(L("The draft is gone.")) }
        guard let last = draft.testRunIDs.last.flatMap({ WorkflowRunStore.shared.run(id: $0) }) else {
            return refuse(L("Run the whole test once first."))
        }
        switch reusePlan(from: last, nodeID: nodeID, definition: draft.definition) {
        case .failure(let refusal): return refuse(refusal.message)
        case .success(let plan):
            let result = start(
                draftID: draftID, input: plan.input, startAt: plan.startAt, pinned: plan.pinned, reusing: last,
                sessionID: sessionID)
            switch result {
            case .success(let runID):
                Task { @MainActor in
                    guard let run = await WorkflowRunService.shared.result(of: runID) else { return }
                    WorkflowDraftStore.shared.notePending(
                        draftID,
                        "The user tested from step \(nodeID), reusing \(plan.reused.count) earlier step result(s): "
                            + outcomeLine(run))
                }
                return .success(runID)
            case .failure(.missingDraft): return refuse(L("The draft is gone."))
            case .failure(.invalid(let issues)): return refuse(issues.map(\.message).joined(separator: "; "))
            case .failure(.needsSetup): return refuse(L("The draft needs setup on this Mac first."))
            }
        }
    }

    /// A test the user started from the Draft panel. The Architect hears
    /// how it went on its next turn.
    static func startFromPanel(draftID: UUID, input: JSONValue, sessionID: String?) -> Result<UUID, Refusal> {
        let result = start(draftID: draftID, input: input, sessionID: sessionID)
        if case .success(let runID) = result {
            Task { @MainActor in
                guard let run = await WorkflowRunService.shared.result(of: runID) else { return }
                WorkflowDraftStore.shared.notePending(draftID, outcomeLine(run))
            }
        }
        return result
    }

    /// Whether `start` would run `draft` rather than refuse it.
    static func isReady(_ draft: WorkflowDraft) -> Bool {
        guard WorkflowValidator.validate(draft.definition, allowPlaceholders: false).isEmpty else { return false }
        let bindings = WorkflowDraftStore.shared.testBindings(draft.id)
        return !SetupChecker.check(draft.template(), bindings: bindings, subjectId: draft.id, agentsByName: true)
            .hasBlockers
    }

    // MARK: - Folder and file inputs

    /// Folder and file input fields the test `input` has no value for:
    /// the required ones and those a step or the output binds.
    nonisolated static func missingPathFields(_ definition: WorkflowDefinition, input: JSONValue) -> [DialogField] {
        let given = input.objectValue ?? [:]
        let bound = boundInputKeys(definition)
        return WorkflowFormFields.fields(fromInputSchema: definition.inputSchema).filter { field in
            guard field.type == .folder || field.type == .file else { return false }
            let value = given[field.key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty && (field.required || bound.contains(field.key))
        }
    }

    /// The newest earlier test value for `field` that still names an
    /// existing folder (or file) on this Mac.
    nonisolated static func reusablePick(_ field: DialogField, previousInputs: [JSONValue]) -> String? {
        for input in previousInputs {
            guard let path = input.objectValue?[field.key]?.stringValue, path.hasPrefix("/") else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue == (field.type == .folder) { return path }
        }
        return nil
    }

    /// Top-level input keys any node or the output references.
    nonisolated private static func boundInputKeys(_ definition: WorkflowDefinition) -> Set<String> {
        let encoder = JSONEncoder()
        let text = [(try? encoder.encode(definition.nodes)), (try? encoder.encode(definition.output))]
            .compactMap { $0.flatMap { String(data: $0, encoding: .utf8) } }
            .joined(separator: "\n")
        var keys = Set<String>()
        for ref in BindingRenderer.references(in: text) {
            guard case .input(let path)? = BindingRenderer.parse(reference: ref),
                let head = path.split(separator: ".").first
            else { continue }
            keys.insert(String(head))
        }
        return keys
    }

    static func outcomeLine(_ run: WorkflowRun) -> String {
        var line = "The user ran a test from the Draft panel (run \(run.id.uuidString)): \(run.status.rawValue)"
        if let error = run.error {
            line += " — " + (error.nodeID.map { "[\($0)] " } ?? "") + error.reason
        }
        if let failure = run.primaryFailure {
            line += ". " + WorkflowRepairBrief.failureLine(failure) + " " + WorkflowRepairBrief.nextStep(failure.fixIn)
        }
        let notes = WorkflowTestTool.observations(run)
        if !notes.isEmpty { line += ". " + notes.joined(separator: " ") }
        return line
    }
}
