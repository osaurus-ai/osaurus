//
//  WorkflowConnectionOverviewTests.swift
//  OsaurusCoreTests
//
//  What the Workflows window's Connections sheet lists: each connection
//  with its status and the workflows bound to it, and the connection
//  secrets setup has not filled.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowConnectionOverviewTests {
    private static func template(secrets: [SecretRequirement]) -> Template {
        var template = WF.template(
            WorkflowDefinition(
                inputSchema: WF.object([:]),
                nodes: [
                    WorkflowNode(
                        id: "fetch", name: "Fetch",
                        kind: .code(
                            CodeSpec(source: "async function run() { return {} }", secrets: secrets.map(\.key))))
                ],
                output: .object([:])))
        template.requirements.secrets = secrets
        return template
    }

    private static func workflow(_ name: String, _ secrets: [SecretRequirement], bound: [String: String] = [:])
        -> InstalledWorkflow
    {
        InstalledWorkflow(
            template: template(secrets: secrets), bindings: InstallBindings(secrets: bound), name: name)
    }

    private static let github = SecretRequirement(key: "GH_TOKEN", label: "GitHub", service: "api.github.com")

    @Test func entriesCarryStatusAndTheWorkflowsBoundToThem() {
        let live = WorkflowConnection(name: "GitHub · Work", service: "api.github.com", kind: .oauth2)
        let expired = WorkflowConnection(
            name: "Linear", service: "api.linear.app", kind: .oauth2, expiresAt: Date().addingTimeInterval(-60))
        let empty = WorkflowConnection(name: "Clio", service: "app.clio.com", kind: .value)
        let billing = Self.workflow("Billing", [Self.github], bound: ["GH_TOKEN": live.binding])
        let triage = Self.workflow("Triage", [Self.github], bound: ["GH_TOKEN": live.binding])

        let overview = WorkflowConnectionOverview.build(
            connections: [live, expired, empty], workflows: [billing, triage],
            hasValue: { $0.id != empty.id }, isSetUp: { _, _ in false })

        #expect(overview.entries.map(\.status) == [.ready, .signInExpired, .noValue])
        #expect(overview.entries[0].workflows == ["Billing", "Triage"])
        #expect(overview.entries[1].workflows.isEmpty)
        #expect(overview.needs.isEmpty)
    }

    @Test func unboundAndDanglingConnectionSecretsNeedSetup() {
        let removed = WorkflowSecretsKeychain.connectionBinding(id: UUID())
        let unbound = Self.workflow("Unbound", [Self.github])
        let dangling = Self.workflow("Dangling", [Self.github], bound: ["GH_TOKEN": removed])
        let pasted = Self.workflow("Pasted", [Self.github], bound: ["GH_TOKEN": "workflow:pasted:GH_TOKEN"])
        let plain = Self.workflow("Plain", [SecretRequirement(key: "CLIO_API_KEY", label: "Clio")])

        let overview = WorkflowConnectionOverview.build(
            connections: [], workflows: [unbound, dangling, pasted, plain],
            hasValue: { _ in true }, isSetUp: { scope, _ in scope == pasted.id })

        #expect(overview.needs.map(\.workflowName) == ["Unbound", "Dangling"])
        #expect(overview.needs.allSatisfy { $0.secret.key == "GH_TOKEN" })
    }

    @Test @MainActor func aPastedValueIsReplacedNotSignedInAgain() async {
        let pasted = WorkflowConnection(name: "Clio", service: "app.clio.com", kind: .value)
        #expect(WorkflowConnectionActions.pastesValue(pasted))
        await #expect(throws: WorkflowConnectionActions.Failure.self) {
            try await WorkflowConnectionActions.signInAgain(pasted)
        }
    }
}
