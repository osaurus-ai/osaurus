//
//  AgentBundlePlanTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct AgentBundlePlanTests {
    private func workflow(_ name: String, version: Int = 1) -> Template {
        var t = WF.template(WF.intake(), name: name)
        t.version = version
        return t
    }

    private func plan(
        _ refs: [WorkflowReference], bundled: [Template] = [], stored: [Template] = [],
        installed: [InstalledWorkflow] = []
    ) -> AgentBundlePlan {
        AgentBundlePlan.make(
            references: refs, bundled: bundled,
            stored: { id in stored.filter { $0.id == id }.max { $0.version < $1.version } },
            installed: { id in installed.first { $0.templateID == id } })
    }

    @Test func bundledWorkflowNotInstalledMustBeSetUpFirst() {
        let intake = workflow("Client Intake")
        let p = plan([WorkflowReference(id: intake.id, minVersion: 1)], bundled: [intake])
        #expect(p.rows.map(\.state) == [.notInstalled])
        #expect(p.pending.map(\.id) == [intake.id])
        #expect(p.rows.first?.template?.id == intake.id)
        #expect(p.enabledWorkflowIDs.isEmpty)
    }

    @Test func installedAtPinnedVersionOrNewerIsReused() {
        let intake = workflow("Client Intake", version: 3)
        let local = InstalledWorkflow(template: intake, bindings: InstallBindings())
        let p = plan([WorkflowReference(id: intake.id, minVersion: 2)], bundled: [intake], installed: [local])
        #expect(p.rows.map(\.state) == [.installed(local.id)])
        #expect(p.pending.isEmpty)
        #expect(p.enabledWorkflowIDs == [local.id])
    }

    @Test func olderInstallOffersUpdateWithoutBlocking() {
        let old = workflow("Client Intake", version: 1)
        var new = old
        new.version = 2
        let local = InstalledWorkflow(template: old, bindings: InstallBindings())
        let p = plan([WorkflowReference(id: old.id, minVersion: 2)], bundled: [new], installed: [local])
        #expect(p.rows.map(\.state) == [.updateAvailable(local.id, local: 1)])
        #expect(p.rows.first?.template?.version == 2)
        #expect(p.pending.isEmpty)
        #expect(p.enabledWorkflowIDs == [local.id])
    }

    @Test func storedNewerVersionWinsOverBundledCopy() {
        let bundled = workflow("Client Intake", version: 2)
        var stored = bundled
        stored.version = 4
        let p = plan([WorkflowReference(id: bundled.id, minVersion: 2)], bundled: [bundled], stored: [stored])
        #expect(p.rows.first?.template?.version == 4)
    }

    @Test func missingTemplateDoesNotBlockCreation() {
        let p = plan([WorkflowReference(id: UUID(), minVersion: 1)])
        #expect(p.rows.map(\.state) == [.missingTemplate])
        #expect(p.pending.isEmpty)
        #expect(p.enabledWorkflowIDs.isEmpty)
    }

    @Test func versionBelowPinIsNotInstallable() {
        let intake = workflow("Client Intake", version: 1)
        let p = plan([WorkflowReference(id: intake.id, minVersion: 2)], bundled: [intake])
        #expect(p.rows.map(\.state) == [.missingTemplate])
    }

    @Test func duplicateReferencesCollapse() {
        let intake = workflow("Client Intake")
        let ref = WorkflowReference(id: intake.id, minVersion: 1)
        #expect(plan([ref, ref], bundled: [intake]).rows.count == 1)
    }

    @Test func sharedRequirementsListedOnceAndSkipInstalled() {
        var a = workflow("A")
        a.requirements.secrets = [SecretRequirement(key: "crm_token", label: "CRM token")]
        a.requirements.mcpServers = ["CRM"]
        a.requirements.permissions = ["contacts"]
        var b = workflow("B")
        b.requirements.secrets = [SecretRequirement(key: "crm_token", label: "CRM token")]
        b.requirements.mcpServers = ["crm"]
        b.requirements.permissions = ["contacts", "calendar"]
        var c = workflow("C")
        c.requirements.secrets = [SecretRequirement(key: "other", label: "Other")]
        let installedC = InstalledWorkflow(template: c, bindings: InstallBindings())
        let p = plan(
            [a, b, c].map { WorkflowReference(id: $0.id, minVersion: 1) }, bundled: [a, b, c],
            installed: [installedC])
        let shared = p.sharedRequirements
        #expect(shared.secrets == ["CRM token"])
        #expect(shared.mcpServers == ["CRM"])
        #expect(shared.permissions == ["contacts", "calendar"])
    }

    @Test @MainActor func oneModelFillsOnlyUnboundSlots() {
        var t = workflow("A")
        t.requirements.models = [
            ModelRequirement(slot: "classify"), ModelRequirement(slot: "draft"),
        ]
        var subject = WorkflowSetupSubject(mode: .install, template: t, bindings: InstallBindings(), name: "A")
        subject.bindings.models["draft"] = "cloud/gpt"
        let bound = AgentBundlePlan.bindingAllSlots(subject, to: "foundation")
        #expect(bound.bindings.models == ["classify": "foundation", "draft": "cloud/gpt"])
    }

    @Test @MainActor func onePassCoversEveryWorkflowStillToInstall() {
        let a = workflow("A")
        let c = workflow("C")
        let installedC = InstalledWorkflow(template: c, bindings: InstallBindings())
        let p = plan(
            [a, c].map { WorkflowReference(id: $0.id, minVersion: 1) }, bundled: [a, c], installed: [installedC])
        let subjects = p.setupSubjects(oneModel: "foundation")
        #expect(subjects.map(\.template.id) == [a.id])
        #expect(subjects.first?.mode == .install)
        #expect(subjects.first?.bindings.models["decision"] == "foundation")
        #expect(p.setupSubjects(oneModel: nil).first?.bindings.models.isEmpty == true)
    }

    @Test @MainActor func mergedPassAsksASharedSecretOnce_andBindsItOnEveryWorkflow() {
        CredentialStore._withIsolatedStoreForTesting { mergedPassBody() }
    }

    @MainActor private func mergedPassBody() {
        let crm = SecretRequirement(key: "crm_token", label: "CRM token")
        var a = workflow("A")
        a.requirements.secrets = [crm]
        var b = workflow("B")
        b.requirements.secrets = [crm, SecretRequirement(key: "other", label: "Other")]
        var setup = WorkflowBundleSetup(
            subjects: [a, b].map {
                WorkflowSetupSubject(mode: .install, template: $0, bindings: InstallBindings(), name: $0.name)
            })
        #expect(setup.secrets.map(\.key) == ["crm_token", "other"])

        // The step saves into the bundle's scratch scope; binding copies
        // the value into each workflow's own account.
        let scratch = setup.scratchScope
        WorkflowSecretsKeychain.save("tok-1234", account: WorkflowSecretsKeychain.secretAccount(scope: scratch, key: "crm_token"))
        WorkflowSecretsKeychain.save("o-1234", account: WorkflowSecretsKeychain.secretAccount(scope: scratch, key: "other"))
        setup.bindSecret("crm_token", account: WorkflowSecretsKeychain.secretAccount(scope: scratch, key: "crm_token"))
        setup.bindSecret("other", account: WorkflowSecretsKeychain.secretAccount(scope: scratch, key: "other"))
        let own = { (s: WorkflowSetupSubject, key: String) in WorkflowSecretsKeychain.secretAccount(scope: s.subjectID, key: key) }
        #expect(setup.subjects.map { $0.bindings.secrets["crm_token"] } == [own(setup.subjects[0], "crm_token"), own(setup.subjects[1], "crm_token")])
        #expect(setup.subjects[0].bindings.secrets["other"] == nil)
        #expect(setup.subjects[1].bindings.secrets["other"] == own(setup.subjects[1], "other"))
        #expect(WorkflowCredentials.value(scope: a.id, key: "crm_token", agentId: nil) == "tok-1234")
        #expect(WorkflowCredentials.value(scope: b.id, key: "crm_token", agentId: nil) == "tok-1234")
        #expect(setup.secretBindings.secrets == ["crm_token": own(setup.subjects[0], "crm_token"), "other": own(setup.subjects[1], "other")])
        setup.discardScratch()
        #expect(WorkflowCredentials.value(scope: a.id, key: "crm_token", agentId: nil) == "tok-1234")
        #expect(CredentialStore.current.value("CRM_TOKEN", scope: .global) == "tok-1234")

        let item = { (kind: TemplateRequirement.Kind, value: String) in
            SetupItem(kind: kind, severity: .blocking, title: value, detail: "", value: value)
        }
        let first = SetupReport(
            subjectId: a.id, items: [item(.model, "decision"), item(.secret, "crm_token"), item(.mcpServer, "CRM")])
        let second = SetupReport(
            subjectId: b.id,
            items: [item(.model, "decision"), item(.secret, "crm_token"), item(.systemPermission, "contacts")])
        #expect(WorkflowBundleSetup.sharedItems([first, second]).map(\.value) == ["crm_token", "CRM", "contacts"])
    }
}
