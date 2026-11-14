//
//  EventWorkflowActionTests.swift
//  osaurusTests
//
//  The workflow action: payload → input mapping (with schema coercion and
//  validation), the caller an event run carries, how a workflow run's end
//  maps onto the ledger, and the channel reply with the workflow's output.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct EventWorkflowActionTests {
    static func webhookPayload(_ body: String) -> JSONValue {
        let event = OsaurusEvent(
            name: "Hook", source: .webhook(WebhookSourceConfig(verification: .none)),
            action: .workflow(WorkflowEventAction(workflowID: UUID())))
        return EventPayload.webhook(
            event: event, firedAt: Date(), method: "post", headers: ["Content-Type": "application/json"],
            query: [:], body: Data(body.utf8), contentType: "application/json")
    }

    static let schema = WF.object(
        [
            "client": WF.string,
            "count": .object(["type": .string("integer")]),
            "score": WF.number,
            "urgent": WF.bool,
            "tags": .object(["type": .string("array")]),
            "record": .object(["type": .string("object")]),
            "summary": WF.string,
        ],
        required: ["client"])

    // MARK: - Mapping

    @Test func singleBindingKeepsTheRawValueAndTemplatesRenderText() {
        let payload = Self.webhookPayload(#"{"client":"Acme","n":3,"meta":{"id":9}}"#)
        let input = WorkflowInputMapper.input(
            mapping: [
                "client": "{{webhook.body.client}}",
                "record": "{{webhook.body.meta}}",
                "summary": "New order from {{webhook.body.client}} ({{webhook.body.n}})",
                "unbound": "{{ webhook.body.n }}",
            ],
            payload: payload, schema: Self.schema)
        #expect(input.value(atPath: "client") == .string("Acme"))
        #expect(input.value(atPath: "record") == .object(["id": .number(9)]))
        #expect(input.value(atPath: "summary") == .string("New order from Acme (3)"))
        #expect(input.value(atPath: "unbound") == .number(3))
    }

    @Test func mappedStringsAreCoercedToTheDeclaredType() {
        let payload = Self.webhookPayload(
            #"{"count":"12","score":"4.5","urgent":"yes","tags":"[\"a\",\"b\"]","record":"{\"k\":1}","client":42}"#)
        let input = WorkflowInputMapper.input(
            mapping: [
                "count": "{{webhook.body.count}}", "score": "{{webhook.body.score}}",
                "urgent": "{{webhook.body.urgent}}", "tags": "{{webhook.body.tags}}",
                "record": "{{webhook.body.record}}", "client": "{{webhook.body.client}}",
            ],
            payload: payload, schema: Self.schema)
        #expect(input.value(atPath: "count") == .number(12))
        #expect(input.value(atPath: "score") == .number(4.5))
        #expect(input.value(atPath: "urgent") == .bool(true))
        #expect(input.value(atPath: "tags") == .array([.string("a"), .string("b")]))
        #expect(input.value(atPath: "record") == .object(["k": .number(1)]))
        #expect(input.value(atPath: "client") == .string("42"))
    }

    @Test func uncoercibleValuesPassThroughForValidationToReport() {
        #expect(WorkflowInputMapper.coerce(.string("many"), to: "integer") == .string("many"))
        #expect(WorkflowInputMapper.coerce(.string("maybe"), to: "boolean") == .string("maybe"))
        #expect(WorkflowInputMapper.coerce(.string("{"), to: "object") == .string("{"))
        #expect(WorkflowInputMapper.coerce(.number(1), to: nil) == .number(1))
    }

    @Test func nonPayloadBracesAreLeftAsWritten() {
        let payload = Self.webhookPayload("{}")
        #expect(EventTemplate.render("Hi {{name}} — {{event.name}}", payload: payload) == "Hi {{name}} — Hook")
        #expect(EventTemplate.value("{{input.client}}", payload: payload) == .string("{{input.client}}"))
        #expect(EventTemplate.references(in: "{{a}} and {{ b.c }}") == ["a", "b.c"])
    }

    @Test func suggestedMappingUsesEachSourcesNaturalValue() {
        let messageSchema = WF.object(["question": WF.string, "room": WF.string], required: ["question", "room"])
        #expect(
            WorkflowInputMapper.suggestedMapping(schema: messageSchema, sourceKind: .channelMessage)
                == ["question": "{{message.text}}", "room": "{{message.room_id}}"])
        let hookSchema = WF.object(["payload": .object(["type": .string("object")]), "note": WF.string])
        #expect(
            WorkflowInputMapper.suggestedMapping(schema: hookSchema, sourceKind: .webhook)
                == ["payload": "{{webhook.body}}", "note": "{{text}}"])
        let folderSchema = WF.object(["files": .object(["type": .string("array")])], required: ["files"])
        #expect(
            WorkflowInputMapper.suggestedMapping(schema: folderSchema, sourceKind: .folder)
                == ["files": "{{folder.changed_paths}}"])
        #expect(WorkflowInputMapper.suggestedMapping(schema: .object([:]), sourceKind: .schedule).isEmpty)
    }

    // MARK: - Installed workflow

    static func installCodeWorkflow() throws -> (InstalledWorkflow, Template) {
        let definition = WorkflowDefinition(
            inputSchema: schema,
            outputSchema: WF.object(["reply": WF.string]),
            nodes: [WF.code("echo", input: .object(["client": "{{input.client}}"]), output: WF.object([:]))],
            edges: [])
        let template = try TemplateStore.shared.save(
            WF.template(definition, name: "Event Echo \(UUID().uuidString.prefix(6))"))
        let installed = try InstalledWorkflowStore.shared.install(template, bindings: InstallBindings())
        return (installed, template)
    }

    @Test func workflowInputValidatesAgainstTheInstalledSchema() throws {
        let (installed, template) = try Self.installCodeWorkflow()
        defer {
            InstalledWorkflowStore.shared.delete(id: installed.id)
            try? TemplateStore.shared.delete(id: template.id)
        }
        let payload = Self.webhookPayload(#"{"client":"Acme","count":"2"}"#)

        let ok = WorkflowRunWorker.workflowInput(
            WorkflowEventAction(
                workflowID: installed.id,
                inputMapping: ["client": "{{webhook.body.client}}", "count": "{{webhook.body.count}}"]),
            payload: payload)
        guard case .success(let (workflow, input)) = ok else {
            Issue.record("expected the mapping to validate, got \(ok)")
            return
        }
        #expect(workflow.id == installed.id)
        #expect(input == .object(["client": .string("Acme"), "count": .number(2)]))

        let missingRequired = WorkflowRunWorker.workflowInput(
            WorkflowEventAction(workflowID: installed.id, inputMapping: ["count": "{{webhook.body.count}}"]),
            payload: payload)
        guard case .failure(let outcome) = missingRequired else {
            Issue.record("a missing required field must not validate")
            return
        }
        #expect(outcome.status == .failed)
        #expect(outcome.reason == "invalid_input")
        #expect(outcome.error?.contains("client") == true)
    }

    @Test func anAutomationWithoutRunAsUsesSharedKeys_andItsRunAsAgentsOwnValueCounts() throws {
        try CredentialStore._withIsolatedStoreForTesting {
            var template = WF.template(
                WorkflowDefinition(
                    inputSchema: WF.object([:]),
                    nodes: [
                        WorkflowNode(
                            id: "fetch", name: "Fetch",
                            kind: .code(
                                CodeSpec(source: "async function run() { return {} }", secrets: ["CLIO_API_KEY"])))
                    ],
                    output: .object([:])),
                name: "Event Keys \(UUID().uuidString.prefix(6))")
            template.requirements.secrets = [SecretRequirement(key: "CLIO_API_KEY", label: "Clio")]
            let installed = try InstalledWorkflowStore.shared.install(template, bindings: InstallBindings())
            defer { InstalledWorkflowStore.shared.delete(id: installed.id) }
            let agent = UUID()
            CredentialStore.current.save(
                "CLIO_API_KEY", scope: .agent(agent), value: "agent-only", kind: .secret, origin: .workflow)
            let shared = WorkflowEventAction(workflowID: installed.id)

            guard
                case .failure(let outcome) = WorkflowRunWorker.workflowInput(
                    shared, payload: .object([:]), agentId: shared.runAsAgentId)
            else {
                Issue.record("an automation with no Run as agent has no shared value to use")
                return
            }
            #expect(outcome.reason == "workflow_missing_keys")
            #expect(outcome.error?.contains("CLIO_API_KEY") == true)
            #expect(InstalledWorkflowStore.shared.workflow(id: installed.id)?.needsSetup == false)

            let runAs = WorkflowEventAction(workflowID: installed.id, runAsAgentId: agent)
            guard
                case .success = WorkflowRunWorker.workflowInput(
                    runAs, payload: .object([:]), agentId: runAs.runAsAgentId)
            else {
                Issue.record("the Run as agent has its own value")
                return
            }
        }
    }

    @Test func runAsSetsTheCallersAgent_andOlderAutomationsDecodeWithout() throws {
        let agent = UUID()
        let event = OsaurusEvent(
            name: "Nightly", source: .webhook(WebhookSourceConfig()),
            action: .workflow(WorkflowEventAction(workflowID: UUID(), runAsAgentId: agent)))
        let caller = WorkflowRunWorker.workflowCaller(
            event: event, occurrence: EventOccurrence(eventId: event.id, payload: .null))
        #expect(caller.agentID == agent)
        #expect(caller.credentialAgentID == agent)

        let plain = OsaurusEvent(
            name: "Plain", source: .webhook(WebhookSourceConfig()),
            action: .workflow(WorkflowEventAction(workflowID: UUID())))
        let sharedCaller = WorkflowRunWorker.workflowCaller(
            event: plain, occurrence: EventOccurrence(eventId: plain.id, payload: .null))
        #expect(sharedCaller.agentID == nil)
        #expect(sharedCaller.credentialAgentID == nil)

        let roundTrip = try JSONDecoder().decode(
            WorkflowEventAction.self, from: JSONEncoder().encode(WorkflowEventAction(workflowID: agent, runAsAgentId: agent)))
        #expect(roundTrip.runAsAgentId == agent)
        let older = try JSONDecoder().decode(
            WorkflowEventAction.self, from: Data(#"{"workflowID":"\#(agent.uuidString)","inputMapping":{}}"#.utf8))
        #expect(older.runAsAgentId == nil)
    }

    @Test func unknownWorkflowIsUnavailable() {
        let result = WorkflowRunWorker.workflowInput(WorkflowEventAction(workflowID: UUID()), payload: .object([:]))
        guard case .failure(let outcome) = result else {
            Issue.record("an unknown workflow must not run")
            return
        }
        #expect(outcome.status == .suppressed)
        #expect(outcome.reason == "workflow_unavailable")
    }

    @Test func managerRefusesAWorkflowEventWhoseWorkflowIsGone() throws {
        let ledger = EventRunDatabase()
        try ledger.openInMemory()
        let manager = EventManager(ledger: ledger, persistsToDisk: false)
        let event = manager.create(
            OsaurusEvent(
                name: "Orphan", source: .webhook(WebhookSourceConfig(verification: .none)),
                action: .workflow(WorkflowEventAction(workflowID: UUID()))))
        let result = manager.submit(EventOccurrence(eventId: event.id, payload: .object([:])))
        #expect(result.status == .suppressed)
        #expect(result.reason == "workflow_deleted")
    }

    // MARK: - Caller

    @Test func callerMarksExternalAndUnattendedFiresCorrectly() {
        let event = OsaurusEvent(
            name: "Nightly", source: .webhook(WebhookSourceConfig()),
            action: .workflow(WorkflowEventAction(workflowID: UUID())))
        let external = WorkflowRunWorker.workflowCaller(
            event: event, occurrence: EventOccurrence(eventId: event.id, payload: .null, isExternal: true))
        #expect(external.kind == .event)
        #expect(external.background)
        #expect(external.isExternalSurface)
        #expect(!external.isUnattendedDispatch)
        #expect(external.eventID == event.id)
        #expect(external.eventName == "Nightly")

        let local = WorkflowRunWorker.workflowCaller(
            event: event,
            occurrence: EventOccurrence(eventId: event.id, payload: .null, folderPath: "/tmp/inbox"))
        #expect(!local.isExternalSurface)
        #expect(local.isUnattendedDispatch)
        #expect(local.folderPath == "/tmp/inbox")

        let manual = WorkflowRunWorker.workflowCaller(
            event: event, occurrence: EventOccurrence(eventId: event.id, payload: .null, trigger: .manual))
        #expect(!manual.isUnattendedDispatch)
    }

    // MARK: - Outcome

    static func run(_ status: WorkflowRunStatus, error: WorkflowRunError? = nil) -> WorkflowRun {
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "W", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .event), input: .object([:]), nodeIDs: [])
        run.status = status
        run.error = error
        return run
    }

    @Test func workflowRunEndsMapOntoTheLedger() {
        let id = UUID()
        #expect(WorkflowRunWorker.outcome(of: Self.run(.completed), runID: id).status == .succeeded)
        #expect(WorkflowRunWorker.outcome(of: Self.run(.awaitingUser), runID: id).status == .waitingUser)
        #expect(WorkflowRunWorker.outcome(of: Self.run(.cancelled), runID: id).status == .cancelled)
        let failed = WorkflowRunWorker.outcome(
            of: Self.run(.failed, error: WorkflowRunError(nodeID: "echo", reason: "boom")), runID: id)
        #expect(failed.status == .failed)
        #expect(failed.error == "[echo] boom")
        #expect(failed.workflowRunId == id)
        #expect(WorkflowRunWorker.outcome(of: nil, runID: id).status == .failed)
    }

    @Test func replyTextPicksTheReadableField() {
        #expect(WorkflowRunWorker.replyText(from: nil) == nil)
        #expect(WorkflowRunWorker.replyText(from: .null) == nil)
        #expect(WorkflowRunWorker.replyText(from: .string("")) == nil)
        #expect(WorkflowRunWorker.replyText(from: .string("Done")) == "Done")
        #expect(WorkflowRunWorker.replyText(from: .object(["reply": .string("Hi"), "extra": .string("x")])) == "Hi")
        #expect(WorkflowRunWorker.replyText(from: .object(["summary": .string("S"), "count": .number(2)])) == "S")
        #expect(WorkflowRunWorker.replyText(from: .object(["only": .string("one"), "n": .number(1)])) == "one")
        let json = WorkflowRunWorker.replyText(from: .object(["a": .number(1), "b": .number(2)]))
        #expect(json?.contains("\"a\"") == true)
        #expect(WorkflowRunWorker.replyText(from: .array([.string("x"), .string("y")])) == "x\ny")
    }

    // MARK: - Reply with output

    actor SentReplies {
        var texts: [String] = []
        func append(_ text: String) { texts.append(text) }
    }

    @Test func channelWorkflowEventRepliesWithTheWorkflowOutput() async throws {
        let (installed, template) = try Self.installCodeWorkflow()
        defer {
            InstalledWorkflowStore.shared.delete(id: installed.id)
            try? TemplateStore.shared.delete(id: template.id)
        }
        let ledger = EventRunDatabase()
        try ledger.openInMemory()
        let manager = EventManager(ledger: ledger, persistsToDisk: false)
        let event = manager.create(
            OsaurusEvent(
                name: "Triage",
                source: .channelMessage(ChannelMessageSourceConfig(kind: .telegram, connectionId: "native")),
                action: .workflow(WorkflowEventAction(workflowID: installed.id)),
                reply: EventReplyPolicy(replyWithWorkflowOutput: true)))

        var workflowRun = Self.run(.completed)
        workflowRun.output = .object(["reply": .string("Filed as P2")])
        WorkflowRunStore.shared.record(workflowRun)
        manager.runAction = { _, _, _, onStarted in
            onStarted(nil, workflowRun.id)
            return TaskOutcome(status: .succeeded, workflowRunId: workflowRun.id)
        }

        let sent = SentReplies()
        let sink = ChannelReplySink(
            connectionId: "native",
            providerRoute: AgentChannelProviderRoute(conversationId: "room-1"),
            reply: { text in await sent.append(text) })
        let finished = await manager.submitAndWait(
            EventOccurrence(eventId: event.id, payload: .object(["text": .string("hi")]), replySink: sink))

        #expect(finished.status == .succeeded)
        #expect(finished.workflowRunId == workflowRun.id)
        #expect(finished.summary["replied"] == "true")
        #expect(await sent.texts == ["Filed as P2"])
    }

    /// A channel rule that posts the output, around a workflow run whose
    /// `reply` step did or did not post already.
    func runReplyingWorkflow(status: WorkflowRunStatus, stepReplied: Bool) async throws
        -> (EventRun, [String])
    {
        let (installed, template) = try Self.installCodeWorkflow()
        defer {
            InstalledWorkflowStore.shared.delete(id: installed.id)
            try? TemplateStore.shared.delete(id: template.id)
        }
        let ledger = EventRunDatabase()
        try ledger.openInMemory()
        let manager = EventManager(ledger: ledger, persistsToDisk: false)
        let event = manager.create(
            OsaurusEvent(
                name: "Triage",
                source: .channelMessage(ChannelMessageSourceConfig(kind: .telegram, connectionId: "native")),
                action: .workflow(WorkflowEventAction(workflowID: installed.id)),
                reply: EventReplyPolicy(replyWithWorkflowOutput: true)))

        var workflowRun = Self.run(status == .completed ? .completed : .failed)
        workflowRun.output = .object(["reply": .string("Filed as P2")])
        WorkflowRunStore.shared.record(workflowRun)
        let runID = workflowRun.id
        manager.runAction = { _, _, _, onStarted in
            onStarted(nil, runID)
            if stepReplied { ChannelReplyRegistry.shared.markReplied(runID: runID) }
            return TaskOutcome(status: status == .completed ? .succeeded : .failed, workflowRunId: runID)
        }

        let sent = SentReplies()
        let sink = ChannelReplySink(
            connectionId: "native",
            providerRoute: AgentChannelProviderRoute(conversationId: "room-1"),
            reply: { text in await sent.append(text) },
            writeGate: WorkflowReplyStepTests.gate())
        let finished = await manager.submitAndWait(
            EventOccurrence(eventId: event.id, payload: .object(["text": .string("hi")]), replySink: sink))
        #expect(
            ChannelReplyRegistry.shared.hasStepReplied(runID: runID) == stepReplied,
            "the reply count stays on the run record; the final post does not add to it")
        #expect((WorkflowRunStore.shared.run(id: runID)?.channelReplyCount ?? 0) == (stepReplied ? 1 : 0))
        return (finished, await sent.texts)
    }

    @Test func aReplyStepThatPostedStandsInForTheOutput() async throws {
        let (finished, texts) = try await runReplyingWorkflow(status: .completed, stepReplied: true)
        #expect(finished.status == .succeeded)
        #expect(texts.isEmpty)
        #expect(finished.summary["replied_by_step"] == "true")
        #expect(finished.summary["replied"] == nil)
    }

    @Test func aFailedRunStillSaysSoAfterAReplyStep() async throws {
        let (finished, texts) = try await runReplyingWorkflow(status: .failed, stepReplied: true)
        #expect(finished.status == .failed)
        #expect(texts.count == 1)
        #expect(texts.first?.contains("Triage") == true)
    }

    actor ConnectionSends {
        var texts: [String] = []
        func append(_ text: String) { texts.append(text) }
    }

    @Test func aRunLeftOpenAtQuitIsFollowedAndStillPostsAfterRelaunch() async throws {
        let (installed, template) = try Self.installCodeWorkflow()
        defer {
            InstalledWorkflowStore.shared.delete(id: installed.id)
            try? TemplateStore.shared.delete(id: template.id)
        }
        let ledger = EventRunDatabase()
        try ledger.openInMemory()
        let manager = EventManager(ledger: ledger, persistsToDisk: false)
        let event = manager.create(
            OsaurusEvent(
                name: "Triage",
                source: .channelMessage(ChannelMessageSourceConfig(kind: .telegram, connectionId: "native")),
                action: .workflow(WorkflowEventAction(workflowID: installed.id)),
                reply: EventReplyPolicy(replyWithWorkflowOutput: true)))

        let target = WorkflowChannelReplyTarget(connectionId: "native", kind: .telegram, conversationId: "room-1")
        var parked = WorkflowRun(
            workflowID: installed.id, workflowName: "W", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .event, eventID: event.id, channelReply: target), input: .object([:]),
            nodeIDs: [])
        parked.status = .awaitingUser
        WorkflowRunStore.shared.record(parked)
        let followed = EventRun(
            eventId: event.id, eventName: event.name, sourceKind: .channelMessage, actionKind: .workflow,
            status: .awaitingUser, workflowRunId: parked.id)
        let orphan = EventRun(
            eventId: event.id, eventName: event.name, sourceKind: .channelMessage, actionKind: .workflow,
            status: .running)
        try ledger.upsert(followed)
        try ledger.upsert(orphan)

        let sends = ConnectionSends()
        manager.channelReplier = WorkflowChannelReplier(
            resolveSink: { _, _ in nil },
            sendThroughConnection: { _, text in await sends.append(text) },
            markReplied: { _ in })
        manager.resumedWorkflowResult = { id in
            var done = parked
            done.status = .completed
            done.output = .object(["reply": .string("Filed after relaunch")])
            WorkflowRunStore.shared.record(done)
            return WorkflowRunStore.shared.run(id: id)
        }

        await manager.closeInterruptedRuns()
        var settled: EventRun?
        for _ in 0..<200 {
            if let row = try ledger.run(id: followed.id), row.status.isTerminal {
                settled = row
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(settled?.status == .succeeded)
        #expect(settled?.summary["replied"] == "true")
        #expect(await sends.texts == ["Filed after relaunch"])
        let closed = try ledger.run(id: orphan.id)
        #expect(closed?.status == .cancelled)
        #expect(closed?.reason == "interrupted")
    }

    @Test func replySinkSendsNothingWhileGlobalWritesAreOff() async throws {
        let gate = ChannelWriteKillSwitch(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("kill-switch-\(UUID().uuidString).json"))
        _ = try gate.disableWrites()
        let sent = SentReplies()
        let sink = ChannelReplySink(
            connectionId: "native",
            providerRoute: AgentChannelProviderRoute(conversationId: "room-1"),
            reply: { text in await sent.append(text) },
            writeGate: gate)

        let failure = await sink.send("Filed as P2", agentId: nil, sessionId: nil)

        #expect(failure != nil)
        #expect(await sent.texts.isEmpty)

        _ = try gate.enableWrites()
        #expect(await sink.send("Filed as P2", agentId: nil, sessionId: nil) == nil)
        #expect(await sent.texts == ["Filed as P2"])
    }
}
