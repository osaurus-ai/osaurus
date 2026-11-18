//
//  WorkflowReplyStepTests.swift
//  osaurusTests
//
//  The `reply` step: its spec and validation, the `caller.channel`
//  bindings it reads, the caller's stored conversation, and the executor
//  against a fake replier (sent, no conversation, test run, files, and
//  refused sends).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Workflow reply step")
struct WorkflowReplyStepTests {

    static let target = WorkflowChannelReplyTarget(
        connectionId: "tg-main", kind: .telegram, conversationId: "chat-42", threadId: nil,
        senderId: "u-7", senderName: "Dana", displayName: "Support")

    static func replyNode(_ spec: ReplySpec) -> WorkflowNode {
        WorkflowNode(id: "ack", name: "Ack", kind: .reply(spec))
    }

    static func definition(_ nodes: [WorkflowNode]) -> WorkflowDefinition {
        WorkflowDefinition(
            inputSchema: WF.object(["text": WF.string]), outputSchema: WF.object([:]), nodes: nodes, edges: [],
            output: .object([:]))
    }

    // MARK: - Spec and validation

    @Test
    func spec_roundTripsAndDefaultsTextWhenMissing() throws {
        let node = Self.replyNode(ReplySpec(text: "On it, {{caller.channel.sender_name}}", file: "{{nodes.make.output.path}}", caption: "Report"))
        let data = try JSONEncoder().encode(node)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["kind"] as? String == "reply")
        #expect((json["reply"] as? [String: Any])?["caption"] as? String == "Report")
        let decoded = try JSONDecoder().decode(WorkflowNode.self, from: data)
        #expect(decoded.kind == node.kind)

        let fileOnly = try JSONDecoder().decode(ReplySpec.self, from: Data(#"{"file":"out.pdf"}"#.utf8))
        #expect(fileOnly.text == "")
        #expect(fileOnly.hasFile && !fileOnly.hasText)
        #expect(WorkflowNode.kindNames.contains("reply"))
        #expect(decoded.effectiveOutputSchema == ReplySpec.outputSchema)
    }

    @Test
    func validator_needsTextOrFileAndKeepsCaptionWithAFile() {
        func issues(_ spec: ReplySpec) -> [String] {
            WorkflowValidator.validate(Self.definition([Self.replyNode(spec)]), allowPlaceholders: false).map(\.message)
        }
        #expect(issues(ReplySpec(text: "Hi")).isEmpty)
        #expect(issues(ReplySpec(file: "{{run.workspace}}/out.txt")).isEmpty)
        #expect(issues(ReplySpec(text: "  ")).contains { $0.contains("reply needs") })
        #expect(issues(ReplySpec(text: "Hi", caption: "Look")).contains { $0.contains("caption") })
        #expect(issues(ReplySpec(text: "Hi", file: "/Users/someone/report.pdf")).contains { $0.contains("names a file on this Mac") })
        #expect(issues(ReplySpec(text: "Done: {{nodes.missing.output.x}}")).contains { $0.contains("missing") })
    }

    @Test
    func hasReplyStep_seesTopLevelAndMapBodies() {
        #expect(!Self.definition([WF.code("a")]).hasReplyStep)
        #expect(Self.definition([Self.replyNode(ReplySpec(text: "Hi"))]).hasReplyStep)
        let map = WorkflowNode(
            id: "each", name: "Each",
            kind: .map(
                MapSpec(
                    items: "{{input.items}}",
                    step: .object(["name": .string("Say"), "kind": .string("reply"), "reply": .object(["text": .string("{{item}}")])]))))
        #expect(Self.definition([map]).hasReplyStep)
    }

    // MARK: - Bindings and the caller

    @Test
    func callerChannel_parsesRendersAndIsUntrusted() {
        let ref = BindingRenderer.parse(reference: "caller.channel.sender_name")
        #expect(ref == .caller(field: "channel.sender_name"))
        #expect(!BindingRenderer.isTrusted(ref, trustInput: true))
        #expect(!BindingRenderer.isTrusted(.caller(field: "channel"), trustInput: true))
        #expect(BindingRenderer.isTrusted(.caller(field: "kind"), trustInput: false))
        #expect(BindingRenderer.parse(reference: "caller.channel.bogus") == nil)

        let caller = WorkflowCaller(kind: .event, channelReply: Self.target)
        let ctx = BindingContext(input: .object([:]), outputs: [:], run: .object([:]), caller: BindingContext.callerValue(caller))
        #expect(BindingRenderer.renderText("Hi {{caller.channel.sender_name}} in {{caller.channel.room_name}}", in: ctx) == "Hi Dana in Support")
        #expect(BindingContext.callerValue(WorkflowCaller(kind: .user)).value(atPath: "channel") == .null)

        let split = BindingRenderer.renderTextSplittingUntrusted(
            "Greet {{caller.channel.sender_name}} as {{caller.kind}}", in: ctx, trustInput: true)
        #expect(!split.text.contains("Dana"))
        #expect(split.text.contains("event"))
    }

    @Test
    func caller_decodesOldRunsAndKeepsTheConversationForSubworkflows() throws {
        let old = #"{"kind":"event","ancestors":[],"background":true,"is_external_surface":false,"has_remote_reviewer":false,"is_unattended_dispatch":false}"#
        let decoded = try JSONDecoder().decode(WorkflowCaller.self, from: Data(old.utf8))
        #expect(decoded.channelReply == nil)

        let caller = WorkflowCaller(kind: .event, channelReply: Self.target)
        let data = try JSONEncoder().encode(caller)
        #expect(String(decoding: data, as: UTF8.self).contains("\"channel_reply\""))
        #expect(try JSONDecoder().decode(WorkflowCaller.self, from: data).channelReply == Self.target)
        #expect(Self.target.conversationKey == "tg-main|chat-42|")
    }

    // MARK: - Executor

    actor Log {
        var texts: [String] = []
        var files: [String] = []
        var marked: [UUID] = []
        func text(_ t: String) { texts.append(t) }
        func file(_ f: String) { files.append(f) }
        func mark(_ id: UUID) { marked.append(id) }
    }

    static func gate() -> ChannelWriteKillSwitch {
        ChannelWriteKillSwitch(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("ks-\(UUID().uuidString).json"))
    }

    /// A replier whose live sink records sends; `attachments` false leaves
    /// the sink without a file responder, `liveSink` false forces the
    /// connection path.
    static func replier(
        _ log: Log, liveSink: Bool = true, attachments: Bool = true, replyCount: Int = 0,
        connection: @escaping @Sendable (String) async throws -> Void = { _ in }
    ) -> WorkflowChannelReplier {
        let gate = gate()
        var replier = WorkflowChannelReplier(
            resolveSink: { runID, caller in
                guard liveSink, caller.channelReply != nil else { return nil }
                let fileResponder: AgentChannelInboundAttachmentReplyHandler = { path, _ in await log.file(path) }
                let sink = ChannelReplySink(
                    connectionId: "tg-main", providerRoute: AgentChannelProviderRoute(conversationId: "chat-42"),
                    reply: { await log.text($0) },
                    replyAttachment: attachments ? fileResponder : nil,
                    writeGate: gate)
                return ChannelReplyRegistry.Resolved(sink: sink, ownerRunID: runID)
            },
            sendThroughConnection: { _, text in
                try await connection(text)
                await log.text(text)
            },
            markReplied: { await log.mark($0) })
        replier.sendAttachmentThroughConnection = { _, path, _ in await log.file(path) }
        replier.replyCount = { _ in replyCount }
        return replier
    }

    static func context(
        _ spec: ReplySpec, caller: WorkflowCaller, workspace: URL = WF.tempDir(), runID: UUID = UUID()
    ) -> WorkflowNodeContext {
        WorkflowNodeContext(
            runID: runID, workflowID: UUID(), workflowName: "Triage", node: replyNode(spec), input: .object([:]),
            bindings: BindingContext(
                input: .object(["text": .string("printer down")]), outputs: [:], run: .object([:]),
                caller: BindingContext.callerValue(caller)),
            model: nil, secretAccounts: [:], caller: caller, workspace: workspace, attempt: 1, timeout: 30)
    }

    @Test
    func executor_postsRenderedTextAndMarksTheRun() async throws {
        let log = Log()
        let runID = UUID()
        let ctx = Self.context(
            ReplySpec(text: "Got it {{caller.channel.sender_name}}: {{input.text}}"),
            caller: WorkflowCaller(kind: .event, channelReply: Self.target), runID: runID)
        let outcome = try await ReplyNodeExecutor.run(spec: ReplySpec(text: "Got it {{caller.channel.sender_name}}: {{input.text}}"), context: ctx, replier: Self.replier(log))
        #expect(await log.texts == ["Got it Dana: printer down"])
        #expect(await log.marked == [runID])
        #expect(outcome.output.value(atPath: "sent") == .bool(true))
        #expect(outcome.output.value(atPath: "platform") == .string("telegram"))
        #expect(outcome.output.value(atPath: "room_id") == .string("chat-42"))
        #expect(outcome.output.value(atPath: "reason") == .null)
    }

    @Test
    func executor_withoutAConversationGoesOnWithNoConversation() async throws {
        let log = Log()
        let spec = ReplySpec(text: "Hi")
        let outcome = try await ReplyNodeExecutor.run(
            spec: spec, context: Self.context(spec, caller: WorkflowCaller(kind: .user)), replier: Self.replier(log))
        #expect(outcome.output.value(atPath: "sent") == .bool(false))
        #expect(outcome.output.value(atPath: "reason") == .string("no_conversation"))
        #expect(await log.texts.isEmpty)
    }

    @Test
    func executor_testRunLogsInsteadOfSending() async throws {
        let log = Log()
        let workspace = WF.tempDir()
        try Data("x".utf8).write(to: workspace.appendingPathComponent("out.txt"))
        let spec = ReplySpec(text: "Hi", file: "out.txt")
        let outcome = try await ReplyNodeExecutor.run(
            spec: spec, context: Self.context(spec, caller: WorkflowCaller(kind: .test, channelReply: Self.target), workspace: workspace),
            replier: Self.replier(log))
        #expect(outcome.output.value(atPath: "reason") == .string("test_run"))
        #expect(outcome.logs.count == 2)
        #expect(await log.texts.isEmpty)
        #expect(await log.files.isEmpty)
    }

    @Test
    func executor_sendsAFileOrSaysTheChannelCannot() async throws {
        let workspace = WF.tempDir()
        let file = workspace.appendingPathComponent("report.txt")
        try Data("report".utf8).write(to: file)
        let spec = ReplySpec(text: "Here it is", file: "report.txt", caption: "Weekly")
        let caller = WorkflowCaller(kind: .event, channelReply: Self.target)

        let withFiles = Log()
        let sent = try await ReplyNodeExecutor.run(
            spec: spec, context: Self.context(spec, caller: caller, workspace: workspace), replier: Self.replier(withFiles))
        #expect(sent.output.value(atPath: "attachment_sent") == .bool(true))
        #expect(await withFiles.files.map { URL(fileURLWithPath: $0).lastPathComponent } == ["report.txt"])

        let textOnly = Log()
        let partial = try await ReplyNodeExecutor.run(
            spec: spec, context: Self.context(spec, caller: caller, workspace: workspace),
            replier: Self.replier(textOnly, attachments: false))
        #expect(partial.output.value(atPath: "sent") == .bool(true))
        #expect(partial.output.value(atPath: "attachment_sent") == .bool(false))
        #expect(partial.output.value(atPath: "reason") == .string("unsupported_on_telegram"))
        #expect(await textOnly.texts == ["Here it is"])

        let afterRelaunch = Log()
        let noSink = try await ReplyNodeExecutor.run(
            spec: spec, context: Self.context(spec, caller: caller, workspace: workspace),
            replier: Self.replier(afterRelaunch, liveSink: false))
        #expect(noSink.output.value(atPath: "reason") == .string("no_live_connection"))
        #expect(noSink.output.value(atPath: "attachment_sent") == .bool(false))
        #expect(await afterRelaunch.texts == ["Here it is"], "text still goes out through the connection")
        #expect(await afterRelaunch.files.isEmpty)

        var imessage = Self.target
        imessage.kind = .imessage
        let imessageRelaunch = Log()
        let viaConnection = try await ReplyNodeExecutor.run(
            spec: spec,
            context: Self.context(spec, caller: WorkflowCaller(kind: .event, channelReply: imessage), workspace: workspace),
            replier: Self.replier(imessageRelaunch, liveSink: false))
        #expect(viaConnection.output.value(atPath: "attachment_sent") == .bool(true))
        #expect(await imessageRelaunch.files.map { URL(fileURLWithPath: $0).lastPathComponent } == ["report.txt"])
    }

    @Test
    func executor_pastTheCapSendsNothingAndGoesOn() async throws {
        let workspace = WF.tempDir()
        try Data("x".utf8).write(to: workspace.appendingPathComponent("out.txt"))
        let caller = WorkflowCaller(kind: .event, channelReply: Self.target)
        let log = Log()
        let capped = Self.replier(log, replyCount: ReplySpec.maximumRepliesPerRun)

        let text = ReplySpec(text: "One more")
        let outcome = try await ReplyNodeExecutor.run(
            spec: text, context: Self.context(text, caller: caller), replier: capped)
        #expect(outcome.output.value(atPath: "sent") == .bool(false))
        #expect(outcome.output.value(atPath: "reason") == .string("reply_cap"))

        let file = ReplySpec(file: "out.txt")
        let fileOutcome = try await ReplyNodeExecutor.run(
            spec: file, context: Self.context(file, caller: caller, workspace: workspace), replier: capped)
        #expect(fileOutcome.output.value(atPath: "reason") == .string("reply_cap"))
        #expect(await log.texts.isEmpty)
        #expect(await log.files.isEmpty)
        #expect(await log.marked.isEmpty)

        let under = try await ReplyNodeExecutor.run(
            spec: text, context: Self.context(text, caller: caller),
            replier: Self.replier(Log(), replyCount: ReplySpec.maximumRepliesPerRun - 1))
        #expect(under.output.value(atPath: "sent") == .bool(true))
    }

    @Test
    func replier_capCountsTheRunItSpeaksFor() async {
        let parent = UUID()
        let log = Log()
        let gate = Self.gate()
        var replier = WorkflowChannelReplier(
            resolveSink: { _, _ in
                ChannelReplyRegistry.Resolved(
                    sink: ChannelReplySink(
                        connectionId: "tg-main", providerRoute: AgentChannelProviderRoute(conversationId: "chat-42"),
                        reply: { await log.text($0) }, writeGate: gate),
                    ownerRunID: parent)
            },
            sendThroughConnection: { _, _ in },
            markReplied: { await log.mark($0) })
        replier.replyCount = { $0 == parent ? ReplySpec.maximumRepliesPerRun : 0 }
        let delivery = await replier.send(
            "from child", runID: UUID(), caller: WorkflowCaller(kind: .workflow, parentRunID: parent, channelReply: Self.target))
        #expect(delivery == .replyCap)
        #expect(await log.texts.isEmpty)

        let question = await replier.send(
            "Which project?", runID: parent, caller: WorkflowCaller(kind: .event, channelReply: Self.target),
            marksReplied: false)
        #expect(question.sent, "form questions do not count toward the cap")
    }

    @Test
    func executor_saysWhenTheTextWasCutShort() async throws {
        let caller = WorkflowCaller(kind: .event, channelReply: Self.target)
        let long = ReplySpec(text: String(repeating: "a", count: 20_000))
        let cut = try await ReplyNodeExecutor.run(
            spec: long, context: Self.context(long, caller: caller), replier: Self.replier(Log()))
        #expect(cut.output.value(atPath: "truncated") == .bool(true))
        #expect(cut.logs.contains { $0.contains("cut short") })

        let viaConnection = try await ReplyNodeExecutor.run(
            spec: long, context: Self.context(long, caller: caller), replier: Self.replier(Log(), liveSink: false))
        #expect(viaConnection.output.value(atPath: "truncated") == .bool(true))

        let short = ReplySpec(text: "Hi")
        let whole = try await ReplyNodeExecutor.run(
            spec: short, context: Self.context(short, caller: caller), replier: Self.replier(Log()))
        #expect(whole.output.value(atPath: "truncated") == .bool(false))
        #expect(ReplySpec.outputSchema.value(atPath: "properties.truncated") != nil)
    }

    @Test
    func run_decodesWithoutAReplyCountAndKeepsIt() throws {
        var run = WorkflowRun(
            workflowID: UUID(), workflowName: "W", templateID: UUID(), templateVersion: 1,
            caller: WorkflowCaller(kind: .event), input: .object([:]), nodeIDs: [])
        let fresh = try JSONEncoder().encode(run)
        #expect(!String(decoding: fresh, as: UTF8.self).contains("channel_reply_count"))
        #expect(try JSONDecoder().decode(WorkflowRun.self, from: fresh).channelReplyCount == 0)

        run.channelReplyCount = 3
        let counted = try JSONEncoder().encode(run)
        #expect(try JSONDecoder().decode(WorkflowRun.self, from: counted).channelReplyCount == 3)
    }

    @Test
    func validatorWarnsAndTrustBadgeNamesTheCapForAReplyInAMap() {
        let map = WorkflowNode(
            id: "each", name: "Each",
            kind: .map(
                MapSpec(
                    items: "{{input.items}}",
                    step: .object(["name": .string("Say"), "kind": .string("reply"), "reply": .object(["text": .string("{{item}}")])]))))
        let def = Self.definition([map])
        #expect(WorkflowValidator.validate(def, allowPlaceholders: false).allSatisfy { !$0.message.contains("reply_cap") })
        let warnings = WorkflowValidator.warnings(def)
        #expect(warnings.count == 1)
        #expect(warnings.first?.message.contains("\(ReplySpec.maximumRepliesPerRun)") == true)
        #expect(WorkflowValidator.warnings(Self.definition([Self.replyNode(ReplySpec(text: "Hi"))])).isEmpty)

        let badge = WorkflowStepRisk.badges(for: map, in: def, locality: { _ in .local }).first { $0.kind == .replies }
        #expect(badge?.detail?.contains("\(ReplySpec.maximumRepliesPerRun) messages per run") == true)
    }

    @Test
    func executor_refusesAFileOutsideTheRunsFolders() async throws {
        let outside = WF.tempDir().appendingPathComponent("secret.txt")
        try Data("x".utf8).write(to: outside)
        let spec = ReplySpec(text: "Hi", file: outside.path)
        await #expect(throws: WorkflowNodeError.self) {
            try await ReplyNodeExecutor.run(
                spec: spec, context: Self.context(spec, caller: WorkflowCaller(kind: .event, channelReply: Self.target)),
                replier: Self.replier(Log()))
        }
    }

    @Test
    func executor_failedSendFailsTheStepButPausedWritesDoNot() async throws {
        struct Refused: Error {}
        let spec = ReplySpec(text: "Hi")
        let caller = WorkflowCaller(kind: .event, channelReply: Self.target)

        do {
            _ = try await ReplyNodeExecutor.run(
                spec: spec, context: Self.context(spec, caller: caller),
                replier: Self.replier(Log(), liveSink: false, connection: { _ in throw Refused() }))
            Issue.record("a refused send must fail the step")
        } catch WorkflowNodeError.toolFailed(let tool, let kind, _, let retryable) {
            #expect(tool == "reply")
            #expect(kind == "send_failed")
            #expect(retryable)
        }

        let paused = try await ReplyNodeExecutor.run(
            spec: spec, context: Self.context(spec, caller: caller),
            replier: Self.replier(
                Log(), liveSink: false,
                connection: { _ in throw AgentChannelConnectionServiceError.globalWritesDisabled(generation: 1) }))
        #expect(paused.output.value(atPath: "sent") == .bool(false))
        #expect(paused.output.value(atPath: "reason") == .string("writes_paused"))
    }
}
