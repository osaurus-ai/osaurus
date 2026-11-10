//
//  WorkflowModelContractTests.swift
//  osaurusTests
//
//  A slot's `strictness`: `always` makes its preferred model a
//  prerequisite (validator, resolution, setup, test bindings, save
//  evidence); `preferred` is a suggestion the person may override.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct WorkflowModelContractTests {

    private static func env(local: [String] = ["foundation", "mlx-a", "mlx-b"]) -> SetupChecker.Environment {
        var env = SetupChecker.Environment(
            registeredToolNames: [],
            modelCatalog: ConfigModelReference.Catalog(localModelIds: local, providers: []),
            isPermissionGranted: { _ in true }, bookmarkResolves: { _ in true }, knowledgeCollectionExists: { _ in true })
        env.defaultModel = "foundation"
        return env
    }

    private static func definition(_ slot: ModelRequirement) -> WorkflowDefinition {
        var def = WF.intake()
        def.modelSlots = [slot]
        return def
    }

    private static func modelItems(_ report: SetupReport) -> [SetupItem] {
        report.items.filter { $0.kind == .model }
    }

    @Test
    func mayUseCloud_followsTheRequiredModel() {
        let catalog = Self.env().modelCatalog
        #expect(!SetupChecker.mayUseCloud(ModelRequirement(slot: "s", preferred: "mlx-a", strictness: .always), catalog: catalog))
        #expect(SetupChecker.mayUseCloud(ModelRequirement(slot: "s", preferred: "openai/gpt-x", strictness: .always), catalog: catalog))
        #expect(SetupChecker.mayUseCloud(ModelRequirement(slot: "s", preferred: "mlx-a"), catalog: catalog))
        #expect(!SetupChecker.mayUseCloud(ModelRequirement(slot: "s", locality: .localOnly), catalog: catalog))
    }

    @Test
    func validator_rejectsAlwaysWithoutAPreferredModel() {
        let bare = WorkflowValidator.validate(
            Self.definition(ModelRequirement(slot: "decision", strictness: .always)), allowPlaceholders: false)
        #expect(bare.contains { $0.message.contains("`always` but names no `preferred` model") })
        let named = WorkflowValidator.validate(
            Self.definition(ModelRequirement(slot: "decision", preferred: "mlx-a", strictness: .always)),
            allowPlaceholders: false)
        #expect(!named.contains { $0.message.contains("no `preferred` model") })
    }

    @Test
    func always_resolvesOnlyToItsRequiredModel() {
        let slot = ModelRequirement(slot: "decision", preferred: "mlx-a", strictness: .always)
        let env = Self.env()
        #expect(SetupChecker.resolvedModel(for: slot, bindings: InstallBindings(), environment: env) == "mlx-a")
        let other = InstallBindings(models: ["decision": "mlx-b"])
        #expect(SetupChecker.resolvedModel(for: slot, bindings: other, environment: env) == "mlx-a")
        #expect(!SetupChecker.canBind("mlx-b", to: slot, environment: env))
        #expect(SetupChecker.canBind("mlx-a", to: slot, environment: env))

        let missing = SetupChecker.resolvedModel(for: slot, bindings: InstallBindings(), environment: Self.env(local: ["foundation"]))
        #expect(missing == nil, "no fallback to the default model")
    }

    @Test
    func preferred_ordersChoiceThenSuggestionThenDefault() {
        let slot = ModelRequirement(slot: "decision", preferred: "mlx-a")
        let env = Self.env()
        #expect(SetupChecker.resolvedModel(for: slot, bindings: InstallBindings(models: ["decision": "mlx-b"]), environment: env) == "mlx-b")
        #expect(SetupChecker.resolvedModel(for: slot, bindings: InstallBindings(), environment: env) == "mlx-a")
        #expect(SetupChecker.resolvedModel(for: slot, bindings: InstallBindings(), environment: Self.env(local: ["foundation"])) == "foundation")
    }

    @Test
    func setup_blocksAMismatchedBindingAndAMissingRequiredModel() {
        let template = WF.template(Self.definition(ModelRequirement(slot: "decision", preferred: "mlx-a", strictness: .always)))
        let mismatched = SetupChecker.check(
            template, bindings: InstallBindings(models: ["decision": "mlx-b"]), subjectId: UUID(), environment: Self.env())
        let item = Self.modelItems(mismatched).first
        #expect(item?.isBlocking == true)
        #expect(item?.detail.contains("This workflow requires mlx-a") == true)

        let clean = SetupChecker.check(template, bindings: InstallBindings(), subjectId: UUID(), environment: Self.env())
        #expect(Self.modelItems(clean).isEmpty)

        let missing = SetupChecker.check(
            template, bindings: InstallBindings(), subjectId: UUID(), environment: Self.env(local: ["foundation"]))
        #expect(Self.modelItems(missing).first?.detail.contains("This workflow requires mlx-a") == true)
    }

    @Test
    func preferredDefault_namesNoModel() {
        let slot = ModelRequirement(slot: "decision", preferred: "Default")
        #expect(WorkflowModelChoices.suggested(slot) == nil)
        #expect(WorkflowModelChoices.suggested(ModelRequirement(slot: "decision", preferred: " mlx-a ")) == "mlx-a")

        let template = WF.template(Self.definition(slot))
        #expect(Self.modelItems(SetupChecker.check(template, bindings: InstallBindings(), subjectId: UUID(), environment: Self.env())).isEmpty)
        var noDefault = Self.env()
        noDefault.defaultModel = nil
        let item = Self.modelItems(
            SetupChecker.check(template, bindings: InstallBindings(), subjectId: UUID(), environment: noDefault)
        ).first
        #expect(item?.detail == "No default model is set. Choose a model for this slot.")
        #expect(item?.hasNoModel == true)
        #expect(item?.title == "Model for Classify")
    }

    @Test
    func setup_blocksAToolSlotOnAModelThatCannotCallTools() {
        var env = Self.env()
        env.toolCalling = { $0 == "mlx-a" ? false : true }
        let slot = ModelRequirement(slot: "decision", needsToolUse: true)
        let template = WF.template(Self.definition(slot))
        let report = SetupChecker.check(
            template, bindings: InstallBindings(models: ["decision": "mlx-a"]), subjectId: UUID(), environment: env)
        #expect(Self.modelItems(report).first?.detail.contains("can't call tools") == true)
        #expect(!SetupChecker.canBind("mlx-a", to: slot, environment: env))
        #expect(SetupChecker.canBind("mlx-b", to: slot, environment: env))
    }

    @Test
    func testBindings_neverFallBackForAnAlwaysSlot() throws {
        let store = WorkflowDraftStore.shared
        let def = Self.definition(ModelRequirement(slot: "decision", preferred: "mlx-a", strictness: .always))
        let draft = store.create(sessionID: "architect-\(UUID().uuidString)", from: WF.template(def))
        defer { store.delete(draft.id) }
        let current = try #require(store.draft(id: draft.id))

        #expect(WorkflowDraftStore.completedForTest(current, environment: Self.env()).models["decision"] == "mlx-a")
        let without = WorkflowDraftStore.completedForTest(current, environment: Self.env(local: ["foundation"]))
        #expect(without.models["decision"] == nil, "the test is left to fail setup rather than run on another model")
    }

    @Test
    func evidence_countsAPassOnlyOnTheRequiredModel() throws {
        let store = WorkflowDraftStore.shared
        let created = store.create(sessionID: "architect-\(UUID().uuidString)")
        defer { store.delete(created.id) }
        store.applyUserEdit(created.id) {
            $0.definition = Self.definition(ModelRequirement(slot: "decision", preferred: "mlx-a", strictness: .always))
        }
        let draft = try #require(store.draft(id: created.id))

        func run(on model: String) -> WorkflowRun {
            var run = WorkflowRun(
                workflowID: draft.id, workflowName: "Draft", templateID: draft.id, templateVersion: 1,
                caller: WorkflowCaller(kind: .test), input: .object([:]),
                nodeIDs: draft.definition.nodes.map(\.id), startedAt: Date(timeIntervalSinceNow: 5))
            run.status = .completed
            run.update("classify") { $0.model = model }
            return run
        }

        let wrong = WorkflowTestEvidence.evidence(
            for: draft, runs: [run(on: "mlx-b")], base: nil, requiredModels: ["decision": "mlx-a"])
        #expect(wrong.passed == 0)
        #expect(wrong.blocker?.contains("ran on mlx-b, but slot “decision” requires mlx-a") == true)
        #expect(wrong.summary["blocker"] != nil)

        let right = WorkflowTestEvidence.evidence(
            for: draft, runs: [run(on: "mlx-a")], base: nil, requiredModels: ["decision": "mlx-a"])
        #expect(right.passed == 1 && right.blocker == nil)

        let unconstrained = WorkflowTestEvidence.evidence(for: draft, runs: [run(on: "mlx-b")], base: nil)
        #expect(unconstrained.passed == 1, "a preferred slot may run on another model")
    }
}
