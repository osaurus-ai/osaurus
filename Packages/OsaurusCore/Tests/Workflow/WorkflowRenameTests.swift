//
//  WorkflowRenameTests.swift
//  OsaurusCoreTests
//
//  An installed workflow's name is what agents and the Orchestrator call.
//  Saving a renamed draft renames it; a newer template version never does
//  on its own (the mismatch is reported instead); every rename keeps the
//  tool name free, carries the tool's policy, and old names still resolve.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct WorkflowRenameTests {

    private func isolated(_ body: @MainActor @Sendable () async throws -> Void) async throws {
        try await StoragePathsTestLock.shared.run { @MainActor in
            let root = WF.tempDir()
            OsaurusPaths.overrideRoot = root
            TemplateStore.shared.reload()
            InstalledWorkflowStore.shared.reload()
            defer {
                InstalledWorkflowStore.shared.resetForTesting()
                OsaurusPaths.overrideRoot = nil
                TemplateStore.shared.reload()
                try? FileManager.default.removeItem(at: root)
            }
            try await body()
        }
    }

    private static func version(_ template: Template, _ version: Int, name: String) -> Template {
        var next = template
        next.version = version
        next.name = name
        return next.sealed()
    }

    @Test
    func architectSaveWithANewName_renamesTheInstallAndItsTool() async throws {
        try await isolated {
            let drafts = WorkflowDraftStore.shared
            let store = InstalledWorkflowStore.shared
            let draft = drafts.create(sessionID: "architect-\(UUID().uuidString)", from: WF.template(WF.intake()))
            defer { drafts.delete(draft.id) }
            let first = try WorkflowDraftSaver.save(draftID: draft.id, changelog: "First", requireEvidence: false)
            #expect(first.toolName == "workflow_client_intake")

            drafts.applyUserEdit(draft.id) { $0.name = "Client Onboarding" }
            let renamedDraft = try #require(drafts.draft(id: draft.id))
            let notice = try #require(WorkflowDraftSaver.renameNotice(for: renamedDraft))
            #expect(notice.contains("Client Intake") && notice.contains("workflow_client_onboarding"))

            let saved = try WorkflowDraftSaver.save(draftID: draft.id, changelog: "Renamed", requireEvidence: false)
            #expect(saved.id == first.id)
            #expect(saved.name == "Client Onboarding")
            #expect(saved.toolName == "workflow_client_onboarding")
            #expect(saved.nameMismatch == nil)
            #expect(ToolRegistry.shared.requiresAgentContext("workflow_client_onboarding"))
            #expect(!ToolRegistry.shared.requiresAgentContext("workflow_client_intake"))
            #expect(store.workflow(named: "Client Intake")?.id == first.id)
            #expect(store.workflow(named: "workflow_client_intake")?.id == first.id)
        }
    }

    @Test
    func draftFromACustomNamedInstall_startsWithThatName_andSavingKeepsIt() async throws {
        try await isolated {
            let drafts = WorkflowDraftStore.shared
            let store = InstalledWorkflowStore.shared
            let template = WF.template(WF.intake())
            let installed = try store.install(template, bindings: InstallBindings(), name: "My Intake")
            #expect(installed.name == "My Intake")
            #expect(installed.nameMismatch == nil, "a name chosen at install is not a mismatch")

            let draft = drafts.create(sessionID: "architect-\(UUID().uuidString)", from: template)
            defer { drafts.delete(draft.id) }
            #expect(draft.name == "My Intake")
            #expect(WorkflowDraftSaver.renameNotice(for: draft) == nil)
            let saved = try WorkflowDraftSaver.save(draftID: draft.id, changelog: "Edit", requireEvidence: false)
            #expect(saved.id == installed.id)
            #expect(saved.name == "My Intake")
        }
    }

    @Test
    func repinToARenamedVersion_keepsTheName_andReportsTheMismatch() async throws {
        try await isolated {
            let store = InstalledWorkflowStore.shared
            let template = WF.template(WF.intake())
            let installed = try store.install(template, bindings: InstallBindings())

            let updated = try store.install(Self.version(template, 2, name: "Client Onboarding"), bindings: InstallBindings())
            #expect(updated.id == installed.id)
            #expect(updated.name == "Client Intake")
            #expect(updated.toolName == "workflow_client_intake")
            #expect(updated.nameMismatch == "Client Onboarding")
            #expect(store.workflow(named: "Client Onboarding")?.id == installed.id, "the version's name resolves too")

            try store.keepName(id: installed.id)
            #expect(store.workflow(id: installed.id)?.nameMismatch == nil)
            store.reload()
            #expect(store.workflow(id: installed.id)?.nameMismatch == nil, "Keep survives a reload")

            let again = try store.install(Self.version(template, 3, name: "Client Welcome"), bindings: InstallBindings())
            #expect(again.nameMismatch == "Client Welcome", "a later template rename is noticed again")

            let used = try store.rename(id: installed.id, to: "Client Welcome")
            #expect(used.name == "Client Welcome")
            #expect(used.nameMismatch == nil)
            #expect(used.keptName == nil)
        }
    }

    @Test
    func rename_takesAFreeName_movesThePolicy_andRemembersTheOldName() async throws {
        try await isolated {
            let store = InstalledWorkflowStore.shared
            let registry = ToolRegistry.shared
            let intake = try store.install(WF.template(WF.intake()), bindings: InstallBindings())
            let digest = try store.install(WF.template(WF.intake(), name: "Digest"), bindings: InstallBindings())
            defer {
                registry.clearPolicy(for: "workflow_digest")
                registry.clearPolicy(for: "workflow_client_intake_2")
            }
            registry.setPolicy(.deny, for: digest.toolName)

            #expect(store.renamedName(for: "Client Intake", id: digest.id) == "Client Intake 2")
            let renamed = try store.rename(id: digest.id, to: "Client Intake")
            #expect(renamed.name == "Client Intake 2")
            #expect(renamed.toolName == "workflow_client_intake_2")
            #expect(renamed.formerNames == ["Digest"])
            #expect(renamed.nameMismatch == nil, "a chosen name is kept, not a mismatch")
            #expect(registry.configuredPolicy(for: "workflow_client_intake_2") == .deny)
            #expect(registry.configuredPolicy(for: "workflow_digest") == nil)
            // Agents enable workflows by id, so their tool list follows the rename.
            #expect(WorkflowTool.toolNames(enabled: [digest.id]) == ["workflow_client_intake_2"])
            #expect(store.workflow(named: "Digest")?.id == digest.id)
            #expect(store.workflow(named: "Client Intake")?.id == intake.id, "a current name wins over a former one")
            #expect(throws: InstalledWorkflowStore.RenameError.emptyName) {
                try store.rename(id: digest.id, to: "  ")
            }
        }
    }

    @Test
    func aFormerNameTwoWorkflowsHad_resolvesToNeither() async throws {
        try await isolated {
            let store = InstalledWorkflowStore.shared
            let first = try store.install(WF.template(WF.intake(), name: "Shared"), bindings: InstallBindings())
            try store.rename(id: first.id, to: "Alpha")
            let second = try store.install(WF.template(WF.intake(), name: "Shared"), bindings: InstallBindings())
            #expect(second.name == "Shared")
            try store.rename(id: second.id, to: "Beta")
            #expect(store.workflow(named: "Shared") == nil)
            #expect(store.workflow(named: "Alpha")?.id == first.id)
        }
    }

    @Test
    func updateCommit_appliesAChangedName_andKeepsTheCurrentOneOtherwise() async throws {
        try await isolated {
            let store = InstalledWorkflowStore.shared
            let template = WF.template(WF.intake())
            let installed = try store.install(template, bindings: InstallBindings())

            let v2 = Self.version(template, 2, name: "Client Onboarding")
            let kept = try #require(
                try WorkflowSetupWizardView.commit(
                    WorkflowSetupSubject(mode: .update(installed.id), template: v2, bindings: InstallBindings(), name: "Client Intake")))
            #expect(kept.name == "Client Intake")
            #expect(kept.templateVersion == 2)
            #expect(kept.nameMismatch == "Client Onboarding")

            let v3 = Self.version(template, 3, name: "Client Onboarding")
            let taken = try #require(
                try WorkflowSetupWizardView.commit(
                    WorkflowSetupSubject(mode: .update(installed.id), template: v3, bindings: InstallBindings(), name: "Client Onboarding")))
            #expect(taken.name == "Client Onboarding")
            #expect(taken.toolName == "workflow_client_onboarding")
            #expect(taken.nameMismatch == nil)
        }
    }

    @Test
    func aStepCallingTheOldName_stillResolves_andIsListedAsACaller() async throws {
        try await isolated {
            let store = InstalledWorkflowStore.shared
            let child = try store.install(WF.template(WF.intake()), bindings: InstallBindings())
            let parentDefinition = WorkflowDefinition(
                inputSchema: WF.object([:]), outputSchema: WF.object([:]),
                nodes: [WorkflowNode(id: "call", name: "Call", kind: .workflow(SubworkflowSpec(workflow: "Client Intake")))],
                edges: [], output: .object([:]))
            _ = try store.install(WF.template(parentDefinition, name: "Parent"), bindings: InstallBindings())

            let callers = RenameInstalledWorkflowSheet.callers(of: child, in: store)
            #expect(callers.map(\.name) == ["Parent"])

            try store.rename(id: child.id, to: "Client Onboarding")
            let resolved = await SubworkflowNodeExecutor.Runtime.live.resolve("Client Intake")
            #expect(resolved?.workflow.id == child.id)
            #expect(RenameInstalledWorkflowSheet.callers(of: try #require(store.workflow(id: child.id)), in: store).map(\.name) == ["Parent"])
        }
    }
}
