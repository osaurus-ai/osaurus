//
//  WorkflowSecretsTests.swift
//  OsaurusCoreTests
//
//  Install secrets resolve through Keys: a binding naming another
//  workflow's account does not count, a legacy value is read until it is
//  copied in, and every value a run handles is redacted from the run
//  record. Updates that widen where a workflow can reach re-ask.
//

import Foundation
import Testing

@testable import OsaurusCore

struct WorkflowSecretsTests {

    private static func codeTemplate(secrets: [String], network: [String] = []) -> Template {
        WF.template(
            WorkflowDefinition(
                inputSchema: WF.object([:]),
                nodes: [
                    WorkflowNode(
                        id: "fetch", name: "Fetch",
                        kind: .code(CodeSpec(source: "async function run() { return {} }", network: network, secrets: secrets)))
                ],
                output: .object([:])))
    }

    private static func environment() -> SetupChecker.Environment {
        var env = SetupChecker.Environment(
            registeredToolNames: [],
            modelCatalog: ConfigModelReference.Catalog(localModelIds: [], providers: []),
            isPermissionGranted: { _ in true }, bookmarkResolves: { _ in true },
            knowledgeCollectionExists: { _ in true })
        env.secretPresent = { WorkflowSecretsKeychain.hasValue(account: $0) }
        return env
    }

    // MARK: - Keychain scoping

    private static func accountsAreScopedByInstall_andReuseIsAnExplicitCopyBody() {
        let a = UUID()
        let b = UUID()
        WorkflowSecretsKeychain.save("token-a", account: WorkflowSecretsKeychain.secretAccount(scope: a, key: "API"))

        #expect(WorkflowCredentials.value(scope: a, key: "API", agentId: nil) == "token-a")
        #expect(WorkflowCredentials.value(scope: b, key: "API", agentId: nil) == nil)
        #expect(WorkflowCredentials.hasValue(scope: b, key: "API") == false)
        #expect(
            WorkflowSecretsKeychain.isSecretAccount(
                WorkflowSecretsKeychain.secretAccount(scope: a, key: "API"), scope: b, key: "API") == false)
        #expect(WorkflowSecretsKeychain.isSecretAccount("secret:API", scope: a, key: "API") == false)

        #expect(WorkflowCredentials.copy(key: "API", from: a, to: b))
        #expect(WorkflowCredentials.value(scope: b, key: "API", agentId: nil) == "token-a")
        #expect(WorkflowCredentials.value(scope: a, key: "API", agentId: nil) == "token-a")
        #expect(WorkflowCredentials.copy(key: "MISSING", from: a, to: b) == false)
    }

    @Test
    func rekeySharesTheValueAndNeverDeletesIt() {
        CredentialStore._withIsolatedStoreForTesting {
            let draft = UUID()
            let installed = UUID()
            let draftAccount = WorkflowSecretsKeychain.secretAccount(scope: draft, key: "A")
            WorkflowSecretsKeychain.save("v-123456", account: draftAccount)

            let bindings = WorkflowCredentials.rekey(["A", "B"], from: draft, to: installed)
            #expect(bindings == ["A": WorkflowSecretsKeychain.secretAccount(scope: installed, key: "A")])
            #expect(WorkflowCredentials.value(scope: installed, key: "A", agentId: nil) == "v-123456")
            #expect(CredentialStore.current.value("A", scope: .global) == "v-123456")

            WorkflowCredentials.forget(keys: ["A"], scope: installed)
            #expect(CredentialStore.current.value("A", scope: .global) == "v-123456")
            #expect(WorkflowSecretsKeychain.read(account: draftAccount) == "v-123456")
        }
    }

    // MARK: - Setup check

    private static func setupCheck_refusesABindingThatNamesAnotherWorkflowsAccountBody() {
        var template = Self.codeTemplate(secrets: ["API"])
        template.requirements.secrets = [SecretRequirement(key: "API", label: "API key")]
        let mine = UUID()
        let theirs = UUID()
        WorkflowSecretsKeychain.save("their-token", account: WorkflowSecretsKeychain.secretAccount(scope: theirs, key: "API"))

        // Pointing at the other install's account: missing, even though a
        // value exists there.
        var foreign = InstallBindings()
        foreign.secrets["API"] = WorkflowSecretsKeychain.secretAccount(scope: theirs, key: "API")
        let refused = SetupChecker.check(template, bindings: foreign, subjectId: mine, environment: Self.environment())
        #expect(refused.items.filter { $0.kind == .secret }.map(\.value) == ["API"])

        // A legacy unscoped account from before per-install scoping too.
        var legacy = InstallBindings()
        legacy.secrets["API"] = "secret:API"
        WorkflowSecretsKeychain.save("old-token", account: "secret:API")
        let reprompt = SetupChecker.check(template, bindings: legacy, subjectId: mine, environment: Self.environment())
        #expect(reprompt.items.filter { $0.kind == .secret }.count == 1)

        // Its own account with a value: clean.
        WorkflowSecretsKeychain.save("my-token", account: WorkflowSecretsKeychain.secretAccount(scope: mine, key: "API"))
        let own = SetupChecker.check(template, bindings: InstallBindings(), subjectId: mine, environment: Self.environment())
        #expect(own.items.filter { $0.kind == .secret }.isEmpty)
    }

    private static func setupCheck_reconfirmMarksAStoredSecretBlockingWithTheReasonBody() {
        var template = Self.codeTemplate(secrets: ["API"], network: ["api.example.com"])
        template.requirements.secrets = [SecretRequirement(key: "API", label: "API key")]
        let mine = UUID()
        WorkflowSecretsKeychain.save("my-token", account: WorkflowSecretsKeychain.secretAccount(scope: mine, key: "API"))

        let report = SetupChecker.check(
            template, bindings: InstallBindings(), subjectId: mine,
            reconfirmSecrets: ["API": "New hosts"], environment: Self.environment())
        let item = report.items.first { $0.kind == .secret }
        #expect(item?.isBlocking == true)
        #expect(item?.detail == "New hosts")
    }

    private static func update_thatWidensAccess_reasksEverySecretBody() {
        var old = TemplateRequirements()
        old.secrets = [SecretRequirement(key: "API", label: "API key")]
        old.network = ["api.example.com"]
        var new = old
        new.network = ["api.example.com", "evil.example.net"]
        let diff = TemplateDiff.newRequirements(from: old, to: new)
        #expect(diff.secrets.isEmpty)
        #expect(diff.network == ["evil.example.net"])
        #expect(diff.widensAccess)

        var template = Self.codeTemplate(secrets: ["API"], network: new.network)
        template.requirements = new
        let subject = WorkflowSetupSubject(mode: .update(UUID()), template: template, bindings: InstallBindings(), name: "W")
        let steps = WorkflowSetupWizardView.steps(
            for: subject, report: SetupReport(subjectId: subject.subjectID, items: []), newRequirements: diff)
        #expect(steps.contains(.secrets))

        // Same version, nothing new: no secrets step on an update.
        let same = TemplateDiff.newRequirements(from: old, to: old)
        #expect(same.widensAccess == false)
        let quiet = WorkflowSetupWizardView.steps(
            for: subject, report: SetupReport(subjectId: subject.subjectID, items: []), newRequirements: same)
        #expect(quiet.contains(.secrets) == false)

        var tools = old
        tools.tools = ["run_shell"]
        #expect(TemplateDiff.newRequirements(from: old, to: tools).tools == ["run_shell"])
        #expect(TemplateDiff.newRequirements(from: old, to: tools).widensAccess)
    }

    // MARK: - Runner

    private static func request(_ template: Template, workflowID: UUID, secretAccounts: [String: String] = [:])
        -> WorkflowRunner.Request
    {
        WorkflowRunner.Request(
            workflowID: workflowID, workflowName: template.name, template: template, secretAccounts: secretAccounts,
            caller: WorkflowCaller(kind: .user), input: .object([:]), workspace: WF.tempDir())
    }

    private static func runner_resolvesOwnSecrets_andRedactsThemFromTheRecordBody() async {
        let workflowID = UUID()
        let template = Self.codeTemplate(secrets: ["API"])
        WorkflowSecretsKeychain.save(
            "sk-live-0123456789", account: WorkflowSecretsKeychain.secretAccount(scope: workflowID, key: "API"))

        let seen = NodeCallLog()
        let executor = ClosureExecutor { ctx, _ in
            await seen.enter(ctx.secrets["API"] ?? "<none>")
            return WorkflowNodeOutcome(
                output: .object(["echo": .string("used sk-live-0123456789 ok"), "sk-live-0123456789": .bool(true)]),
                logs: ["Authorization: Bearer sk-live-0123456789"])
        }
        let collector = RunCollector()
        let run = await WorkflowRunner(request: Self.request(template, workflowID: workflowID), executor: executor) {
            await collector.add($0)
        }.execute()
        let observed = await collector.runs
        #expect(!observed.isEmpty)

        #expect(await seen.calls == ["sk-live-0123456789"])
        #expect(run.status == .completed)
        let node = run.nodes.first { $0.nodeID == "fetch" }
        #expect(node?.output == .object(["echo": .string("used [REDACTED:API] ok"), "[REDACTED:API]": .bool(true)]))
        #expect(node?.logs == ["Authorization: Bearer [REDACTED:API]"])
        let encoded = (try? JSONEncoder().encode(run)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(!encoded.contains("sk-live-0123456789"))
        for snapshot in observed {
            let text = (try? JSONEncoder().encode(snapshot)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(!text.contains("sk-live-0123456789"))
        }
    }

    private static func runner_refusesABindingToAnotherWorkflowsAccountBody() async {
        let mine = UUID()
        let theirs = UUID()
        let template = Self.codeTemplate(secrets: ["API"])
        WorkflowSecretsKeychain.save("their-token-123", account: WorkflowSecretsKeychain.secretAccount(scope: theirs, key: "API"))

        let seen = NodeCallLog()
        let executor = ClosureExecutor { ctx, _ in
            await seen.enter(ctx.node.id)
            return WorkflowNodeOutcome(output: .object([:]))
        }
        let foreign = ["API": WorkflowSecretsKeychain.secretAccount(scope: theirs, key: "API")]
        let run = await WorkflowRunner(
            request: Self.request(template, workflowID: mine, secretAccounts: foreign), executor: executor
        ).execute()
        #expect(run.status == .failed)
        #expect(run.error?.reason.contains("API") == true)
        #expect(await seen.calls.isEmpty)
    }

    private static func runner_redactsSecretDialogAnswersEverywhereDownstreamBody() async {
        let spec = DialogSpec(title: "Login", fields: [DialogField(key: "password", label: "Password", type: .secret)])
        let def = WorkflowDefinition(
            inputSchema: WF.object([:]),
            nodes: [
                WorkflowNode(id: "ask", name: "Ask", kind: .dialog(spec)),
                WorkflowNode(
                    id: "use", name: "Use", kind: .code(CodeSpec(source: "async function run() { return {} }")),
                    input: .object(["pw": "{{nodes.ask.output.password}}"])),
            ],
            edges: [WorkflowEdge(from: "ask", to: "use")],
            output: .object(["summary": "{{nodes.use.output.summary}}"]))
        let template = WF.template(def)
        let executor = ClosureExecutor { ctx, _ in
            switch ctx.node.id {
            case "ask": return WorkflowNodeOutcome(output: .object(["password": .string("hunter2-secret")]))
            default:
                let pw = ctx.input.value(atPath: "pw")?.stringValue ?? "?"
                return WorkflowNodeOutcome(output: .object(["summary": .string("logged in with \(pw)")]))
            }
        }
        let run = await WorkflowRunner(request: Self.request(template, workflowID: UUID()), executor: executor).execute()
        #expect(run.status == .completed)
        let ask = run.nodes.first { $0.nodeID == "ask" }
        #expect(ask?.output == .object(["password": .string("••••••")]))
        let use = run.nodes.first { $0.nodeID == "use" }
        #expect(use?.input == .object(["pw": .string("[REDACTED:password]")]))
        #expect(use?.output == .object(["summary": .string("logged in with [REDACTED:password]")]))
        #expect(run.output == .object(["summary": .string("logged in with [REDACTED:password]")]))
    }

    // Each test gets its own Keys store: values are shared by name, so
    // suites writing the same key would otherwise see each other.
    @Test func accountsAreScopedByInstall_andReuseIsAnExplicitCopy() {
        CredentialStore._withIsolatedStoreForTesting { Self.accountsAreScopedByInstall_andReuseIsAnExplicitCopyBody() }
    }

    @Test func setupCheck_refusesABindingThatNamesAnotherWorkflowsAccount() {
        CredentialStore._withIsolatedStoreForTesting { Self.setupCheck_refusesABindingThatNamesAnotherWorkflowsAccountBody() }
    }

    @Test func setupCheck_reconfirmMarksAStoredSecretBlockingWithTheReason() {
        CredentialStore._withIsolatedStoreForTesting { Self.setupCheck_reconfirmMarksAStoredSecretBlockingWithTheReasonBody() }
    }

    @Test func update_thatWidensAccess_reasksEverySecret() {
        CredentialStore._withIsolatedStoreForTesting { Self.update_thatWidensAccess_reasksEverySecretBody() }
    }

    @Test func runner_resolvesOwnSecrets_andRedactsThemFromTheRecord() async {
        await CredentialStore._withIsolatedStoreForTesting { await Self.runner_resolvesOwnSecrets_andRedactsThemFromTheRecordBody() }
    }

    @Test func runner_refusesABindingToAnotherWorkflowsAccount() async {
        await CredentialStore._withIsolatedStoreForTesting { await Self.runner_refusesABindingToAnotherWorkflowsAccountBody() }
    }

    @Test func runner_redactsSecretDialogAnswersEverywhereDownstream() async {
        await CredentialStore._withIsolatedStoreForTesting { await Self.runner_redactsSecretDialogAnswersEverywhereDownstreamBody() }
    }
}

private actor RunCollector {
    var runs: [WorkflowRun] = []
    func add(_ run: WorkflowRun) { runs.append(run) }
}
