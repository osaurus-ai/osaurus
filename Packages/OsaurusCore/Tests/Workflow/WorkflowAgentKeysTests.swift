//
//  WorkflowAgentKeysTests.swift
//  OsaurusCoreTests
//
//  Workflows belong to no agent: a run with no agent, or the Orchestrator's,
//  uses the shared keys; a custom agent's run uses its own value first; and
//  a workflow installs with plain keys missing (advisory), which only stop a
//  run that lacks them.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowAgentKeysTests {

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

    private static func environment() -> SetupChecker.Environment {
        var env = SetupChecker.Environment(
            registeredToolNames: [],
            modelCatalog: ConfigModelReference.Catalog(localModelIds: [], providers: []),
            isPermissionGranted: { _ in true }, bookmarkResolves: { _ in true },
            knowledgeCollectionExists: { _ in true })
        env.secretPresent = { WorkflowCredentials.isSetUp(account: $0) }
        env.agentSecretPresent = { WorkflowCredentials.isSetUp(account: $0, agentId: $1) }
        return env
    }

    private static func check(
        _ template: Template, subject: UUID, _ audience: SetupChecker.SecretAudience
    ) -> SetupReport {
        SetupChecker.check(
            template, bindings: InstallBindings(), subjectId: subject, secrets: audience, environment: environment())
    }

    private static func saveForAgent(_ key: String, _ value: String, agent: UUID) {
        CredentialStore.current.save(key, scope: .agent(agent), value: value, kind: .secret, origin: .workflow)
    }

    // MARK: - Setup check

    @Test func install_aMissingPlainKeyIsAdvisory_andSignInsStillBlock() {
        CredentialStore._withIsolatedStoreForTesting {
            var oauth = SecretRequirement(key: "GH_TOKEN", label: "GitHub")
            oauth.oauth2 = OAuth2Spec(
                authorizeURL: "https://accounts.example.com/authorize", tokenURL: "https://accounts.example.com/token",
                scopes: ["read"])
            let template = Self.template(secrets: [SecretRequirement(key: "CLIO_API_KEY", label: "Clio"), oauth])
            let report = Self.check(template, subject: UUID(), .install)

            let plain = report.items.first { $0.value == "CLIO_API_KEY" }
            #expect(plain?.isBlocking == false)
            #expect(plain?.isMissingKey == true)
            let signIn = report.items.first { $0.value == "GH_TOKEN" }
            #expect(signIn?.isBlocking == true)
            #expect(signIn?.isMissingKey == false)
            #expect(SetupChecker.missingKeys(report) == ["CLIO_API_KEY"])
            #expect(!SetupChecker.onlyKeysMissing(report), "a sign-in is setup, not Keys")
        }
    }

    @Test func caller_agentOwnValueSatisfiesItsRun_onlyItsRun() {
        CredentialStore._withIsolatedStoreForTesting {
            let template = Self.template(secrets: [SecretRequirement(key: "CLIO_API_KEY", label: "Clio")])
            let subject = UUID()
            let agent = UUID()
            Self.saveForAgent("CLIO_API_KEY", "agent-only", agent: agent)

            let standalone = Self.check(template, subject: subject, .caller(nil))
            #expect(standalone.hasBlockers)
            #expect(SetupChecker.onlyKeysMissing(standalone))
            #expect(Self.check(template, subject: subject, .caller(agent)).isClean)
            #expect(Self.check(template, subject: subject, .caller(UUID())).hasBlockers, "another agent lacks it")
        }
    }

    @Test func caller_sharedValueIsInheritedByEveryCaller() {
        CredentialStore._withIsolatedStoreForTesting {
            let template = Self.template(secrets: [SecretRequirement(key: "CLIO_API_KEY", label: "Clio")])
            let subject = UUID()
            // A key saved once for all agents, before this workflow existed.
            CredentialStore.current.save("CLIO_API_KEY", scope: .global, value: "shared", kind: .secret, origin: .user)

            #expect(Self.check(template, subject: subject, .caller(nil)).isClean)
            #expect(Self.check(template, subject: subject, .caller(UUID())).isClean)
            #expect(Self.check(template, subject: subject, .install).isClean)
        }
    }

    // MARK: - Runner

    private static func run(_ template: Template, workflowID: UUID, agent: UUID?) async -> [String] {
        await run(template, workflowID: workflowID, caller: WorkflowCaller(kind: agent == nil ? .user : .agent, agentID: agent))
    }

    private static func run(_ template: Template, workflowID: UUID, caller: WorkflowCaller) async -> [String] {
        let seen = NodeCallLog()
        let executor = ClosureExecutor { ctx, _ in
            await seen.enter(ctx.secrets["CLIO_API_KEY"] ?? "<none>")
            return WorkflowNodeOutcome(output: .object([:]))
        }
        let request = WorkflowRunner.Request(
            workflowID: workflowID, workflowName: template.name, template: template,
            caller: caller, input: .object([:]),
            workspace: WF.tempDir())
        _ = await WorkflowRunner(request: request, executor: executor).execute()
        return await seen.calls
    }

    @Test func runner_agentOverrideWins_standaloneUsesShared() async {
        await CredentialStore._withIsolatedStoreForTesting {
            let template = Self.template(secrets: [SecretRequirement(key: "CLIO_API_KEY", label: "Clio")])
            let workflowID = UUID()
            let agent = UUID()
            CredentialStore.current.save(
                "CLIO_API_KEY", scope: .global, value: "shared-value", kind: .secret, origin: .user)
            Self.saveForAgent("CLIO_API_KEY", "agent-value", agent: agent)

            #expect(await Self.run(template, workflowID: workflowID, agent: agent) == ["agent-value"])
            #expect(await Self.run(template, workflowID: workflowID, agent: nil) == ["shared-value"])
            #expect(await Self.run(template, workflowID: workflowID, agent: UUID()) == ["shared-value"])
        }
    }

    @Test func credentialAgent_isNilForBuiltInAgents() {
        #expect(WorkflowCaller(kind: .user).credentialAgentID == nil)
        #expect(WorkflowCaller(kind: .orchestrator, agentID: Agent.defaultId).credentialAgentID == nil)
        #expect(WorkflowCaller(kind: .test, agentID: Agent.architectId).credentialAgentID == nil)
        let custom = UUID()
        #expect(WorkflowCaller(kind: .agent, agentID: custom).credentialAgentID == custom)
        let nested = WorkflowCaller(kind: .agent, agentID: custom).nested(parentRunID: UUID(), parentWorkflowID: UUID())
        #expect(nested.credentialAgentID == custom, "a nested step keeps the caller's keys")
    }

    @Test func runner_orchestratorUsesShared_subagentUsesItsOwn() async {
        await CredentialStore._withIsolatedStoreForTesting {
            let template = Self.template(secrets: [SecretRequirement(key: "CLIO_API_KEY", label: "Clio")])
            let workflowID = UUID()
            let subagent = UUID()
            CredentialStore.current.save(
                "CLIO_API_KEY", scope: .global, value: "shared-value", kind: .secret, origin: .user)
            Self.saveForAgent("CLIO_API_KEY", "orchestrator-value", agent: Agent.defaultId)
            Self.saveForAgent("CLIO_API_KEY", "subagent-value", agent: subagent)

            let orchestrator = WorkflowCaller(kind: .orchestrator, agentID: Agent.defaultId)
            #expect(await Self.run(template, workflowID: workflowID, caller: orchestrator) == ["shared-value"])
            // A subagent the Orchestrator handed work to calls its own
            // `workflow_<slug>` tool as itself.
            let delegated = WorkflowCaller(kind: .agent, agentID: subagent)
            #expect(await Self.run(template, workflowID: workflowID, caller: delegated) == ["subagent-value"])
        }
    }

    @Test func setup_orchestratorIsCheckedAgainstSharedKeysOnly() {
        CredentialStore._withIsolatedStoreForTesting {
            let template = Self.template(secrets: [SecretRequirement(key: "CLIO_API_KEY", label: "Clio")])
            Self.saveForAgent("CLIO_API_KEY", "orchestrator-value", agent: Agent.defaultId)
            let caller = WorkflowCaller(kind: .orchestrator, agentID: Agent.defaultId)
            let report = Self.check(template, subject: UUID(), .caller(caller.credentialAgentID))
            #expect(SetupChecker.onlyKeysMissing(report), "the Orchestrator's own value does not count")
        }
    }

    @Test func steps_ofAnOrchestratorRunDoNotLeakAnAgentsPluginKeys() async throws {
        let registering = UUID()
        let node = WorkflowNode(id: "t", name: "T", kind: .tool(ToolNodeSpec(tool: ToolRef(name: "file_write"))))
        func context(_ caller: WorkflowCaller) -> WorkflowNodeContext {
            WorkflowNodeContext(
                runID: UUID(), workflowID: UUID(), workflowName: "W", node: node, input: .object([:]),
                bindings: BindingContext(input: .object([:])), model: nil, secretAccounts: [:], caller: caller,
                workspace: WF.tempDir(), folderRoot: WF.tempDir(), attempt: 1, timeout: 60)
        }
        let orchestrator = try await WorkflowExecutionContext.bind(
            context(WorkflowCaller(kind: .orchestrator, agentID: Agent.defaultId))
        ) { CredentialResolver.credentialAgent(fallback: registering) }
        #expect(orchestrator == nil)

        let custom = UUID()
        let agent = try await WorkflowExecutionContext.bind(context(WorkflowCaller(kind: .agent, agentID: custom))) {
            CredentialResolver.credentialAgent(fallback: registering)
        }
        #expect(agent == custom)
    }

    @Test @MainActor func staleNeedsSetup_isClearedOnlyWhenTheInstallCheckPasses() throws {
        try CredentialStore._withIsolatedStoreForTesting {
            let store = InstalledWorkflowStore.shared
            let installed = try store.install(
                Self.template(secrets: [SecretRequirement(key: "CLIO_API_KEY", label: "Clio")]),
                bindings: InstallBindings())
            defer { store.delete(id: installed.id) }
            store.setNeedsSetup(true, id: installed.id)
            store.clearStaleSetupFlags(ids: [installed.id])
            #expect(store.workflow(id: installed.id)?.needsSetup == false, "a missing plain key is not setup")

            var oauth = SecretRequirement(key: "GH_TOKEN", label: "GitHub")
            oauth.oauth2 = OAuth2Spec(
                authorizeURL: "https://accounts.example.com/authorize", tokenURL: "https://accounts.example.com/token",
                scopes: ["read"])
            var blockedTemplate = Self.template(secrets: [oauth])
            blockedTemplate.name = "Blocked \(UUID().uuidString.prefix(6))"
            let blocked = try store.install(blockedTemplate, bindings: InstallBindings())
            defer { store.delete(id: blocked.id) }
            store.setNeedsSetup(true, id: blocked.id)
            store.clearStaleSetupFlags()
            #expect(store.workflow(id: blocked.id)?.needsSetup == true, "a sign-in still blocks")
        }
    }

    @Test @MainActor func runner_connectionSession_agentPickWinsOverTheWorkflows() async {
        let host = "api.\(UUID().uuidString.prefix(8).lowercased()).example"
        let connections = WorkflowConnectionStore.shared
        let workConnection = WorkflowConnection(name: "Work", service: host, kind: .value)
        let personalConnection = WorkflowConnection(name: "Personal", service: host, kind: .value)
        connections.upsert(workConnection)
        connections.upsert(personalConnection)
        defer {
            connections.delete(id: workConnection.id)
            connections.delete(id: personalConnection.id)
        }
        let work = workConnection.id
        let personal = personalConnection.id
        let sessions = SignInSessionStore.shared
        #expect(sessions.defaultSession(for: .connection(host))?.id == work, "connections mirror as sessions")
        let scout = UUID()
        sessions.assign(agentId: scout, service: .connection(host), sessionId: personal)

        let template = Self.template(secrets: [SecretRequirement(key: "CLIO_API_KEY", label: "Clio")])
        func run(_ caller: WorkflowCaller) async -> [String] {
            let seen = NodeCallLog()
            let executor = ClosureExecutor { ctx, _ in
                await seen.enter(ctx.secrets["CLIO_API_KEY"] ?? "<none>")
                return WorkflowNodeOutcome(output: .object([:]))
            }
            var request = WorkflowRunner.Request(
                workflowID: UUID(), workflowName: template.name, template: template, caller: caller,
                input: .object([:]), workspace: WF.tempDir())
            request.secretAccounts = ["CLIO_API_KEY": WorkflowSecretsKeychain.connectionBinding(id: work)]
            request.connectionSecret = { binding in
                WorkflowSecretsKeychain.connectionID(of: binding) == personal ? "personal-token" : "work-token"
            }
            _ = await WorkflowRunner(request: request, executor: executor).execute()
            return await seen.calls
        }
        #expect(await run(WorkflowCaller(kind: .agent, agentID: scout)) == ["personal-token"])
        #expect(await run(WorkflowCaller(kind: .agent, agentID: UUID())) == ["work-token"], "no pick: the workflow's")
        #expect(await run(WorkflowCaller(kind: .orchestrator, agentID: Agent.defaultId)) == ["work-token"])
        let bound = WorkflowSecretsKeychain.connectionBinding(id: work)
        #expect(WorkflowConnectionSessions.binding(for: bound, agentId: scout) == WorkflowSecretsKeychain.connectionBinding(id: personal))
    }

    // MARK: - Keys page

    @Test func missingKeys_noteAgentsThatHaveTheirOwnValue() {
        CredentialStore._withIsolatedStoreForTesting {
            let store = CredentialStore.current
            let scope = UUID()
            let agent = UUID()
            Self.saveForAgent("CLIO_API_KEY", "agent-only", agent: agent)
            let slot = WorkflowCredentials.slot(scope: scope, key: "CLIO_API_KEY", workflowName: "Billing")

            let missing = CredentialRegistry.buildMissing(slots: [CredentialSlotEntry(slot)], store: store)
            #expect(missing.map(\.key) == ["CLIO_API_KEY"], "runs without an agent still lack it")
            #expect(missing.first?.agentsWithOwnValue == [agent])
            #expect(WorkflowCredentials.agentsWithOwnValue(scope: scope, key: "CLIO_API_KEY", store: store) == [agent])
        }
    }

    @Test @MainActor func missingKeys_ofAnInstall_skipConnectionsAndRespectTheAgent() {
        CredentialStore._withIsolatedStoreForTesting {
            let template = Self.template(secrets: [
                SecretRequirement(key: "CLIO_API_KEY", label: "Clio"),
                SecretRequirement(key: "LINEAR_TOKEN", label: "Linear"),
            ])
            var bindings = InstallBindings()
            bindings.secrets["LINEAR_TOKEN"] = WorkflowSecretsKeychain.connectionBinding(id: UUID())
            let workflow = InstalledWorkflow(template: template, bindings: bindings, name: "Billing")
            let agent = UUID()
            Self.saveForAgent("CLIO_API_KEY", "agent-only", agent: agent)

            #expect(WorkflowCredentials.missingKeys(workflow) == ["CLIO_API_KEY"])
            #expect(WorkflowCredentials.missingKeys(workflow, agentId: agent).isEmpty)
        }
    }

    // MARK: - Failure

    @Test func missingSecret_classifiesAsAMissingKeyFixedInSetup() {
        let failure = WorkflowFailure.classify(WorkflowNodeError.missingSecret(key: "CLIO_API_KEY", forAgent: false))
        #expect(failure.kind == "missing_key")
        #expect(failure.fixIn == .setup)
        #expect(failure.retryable == false)
        #expect(failure.hint?.contains("Vault") == true)
        #expect(WorkflowFailure.message(WorkflowNodeError.missingSecret(key: "K", forAgent: true)).contains("Vault"))
    }
}
