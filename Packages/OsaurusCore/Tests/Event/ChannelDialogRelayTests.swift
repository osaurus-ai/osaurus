//
//  ChannelDialogRelayTests.swift
//  osaurusTests
//
//  Forms asked in the channel conversation: which fields a chat can carry,
//  how a message is read for each field type, the question text, and the
//  round trip from offer to answer (only the original sender, cancel,
//  forms that must be answered on the Mac).
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ChannelDialogRelayTests {

    static let target = WorkflowChannelReplyTarget(
        connectionId: "tg", kind: .telegram, conversationId: "chat-1", senderId: "u-1", senderName: "Dana")

    static func dialog(
        _ fields: [DialogField], kind: WorkflowCaller.Kind = .event, prefill: [String: JSONValue] = [:]
    ) -> PendingDialog {
        PendingDialog(
            id: UUID(), runID: UUID(), workflowID: UUID(), workflowName: "Intake", nodeID: "ask",
            title: "New ticket", message: "A few details", fields: fields, prefill: prefill,
            caller: WorkflowCaller(kind: kind, channelReply: target), createdAt: Date())
    }

    static func message(_ text: String, sender: String = "u-1") -> ChannelInboundMessage {
        ChannelInboundMessage(
            identity: ChannelIdentity(
                kind: .telegram, installationId: "tg", groupId: "chat-1", sender: ChannelSenderMetadata(senderId: sender)),
            kind: .telegram, connectionId: "tg", providerEventId: UUID().uuidString,
            providerRoute: AgentChannelProviderRoute(conversationId: "chat-1"), content: text, sourceLabel: "Telegram")
    }

    @MainActor
    final class Harness {
        var sent: [String] = []
        var answered: [(UUID, [String: JSONValue])] = []
        var dismissed: [UUID] = []
        var pending: Set<UUID> = []
        let relay: ChannelDialogRelay
        private let box = SentBox()

        init(answerResult: Result<Void, DialogAnswerError> = .success(()), storeURL: URL? = nil) {
            relay = ChannelDialogRelay(storeURL: storeURL, runIsOpen: { _ in true })
            let box = self.box
            relay.sendText = { text, _ in
                await box.append(text)
                return WorkflowChannelReplier.Delivery(sent: true, path: .live)
            }
            relay.isPending = { [unowned self] in self.pending.contains($0) }
            relay.answer = { [unowned self] values, id in
                self.answered.append((id, values))
                return answerResult
            }
            relay.dismiss = { [unowned self] in self.dismissed.append($0) }
        }

        func texts() async -> [String] { await box.texts }
    }

    actor SentBox {
        var texts: [String] = []
        func append(_ t: String) { texts.append(t) }
    }

    // MARK: - Pure

    @Test func channelFieldsLeaveOutOptionalFilesAndRefuseRequiredOnes() {
        let text = DialogField(key: "summary", label: "Summary")
        let optionalFile = DialogField(key: "shot", label: "Screenshot", type: .file, required: false)
        let secret = DialogField(key: "token", label: "Token", type: .secret)
        #expect(ChannelDialogRelay.channelFields([text, optionalFile])?.map(\.key) == ["summary"])
        #expect(ChannelDialogRelay.channelFields([text, secret]) == nil)
        #expect(ChannelDialogRelay.channelFields([optionalFile]) == nil)
    }

    @Test func interpretReadsEachFieldType() {
        typealias R = ChannelDialogRelay
        let number = DialogField(key: "n", label: "Count", type: .number)
        let flag = DialogField(key: "b", label: "Urgent", type: .bool)
        let choice = DialogField(key: "c", label: "Project", type: .choice, options: ["Alpha", "Beta"])
        let empty = DialogField(key: "e", label: "Empty", type: .choice, options: [])
        let date = DialogField(key: "d", label: "Due", type: .date)
        let optional = DialogField(key: "o", label: "Notes", required: false)
        let required = DialogField(key: "r", label: "Name")

        #expect(R.interpret("1,200", field: number, prefill: nil) == .value(.number(1200)))
        #expect(R.interpret("lots", field: number, prefill: nil) == .invalid(L("Reply with a number.")))
        #expect(R.interpret("Yes", field: flag, prefill: nil) == .value(.bool(true)))
        #expect(R.interpret("n", field: flag, prefill: nil) == .value(.bool(false)))
        #expect(R.interpret("2", field: choice, prefill: nil) == .value(.string("Beta")))
        #expect(R.interpret("alpha", field: choice, prefill: nil) == .value(.string("Alpha")))
        #expect(R.interpret("3", field: choice, prefill: nil) == .invalid(L("Reply with one of the numbers below.")))
        #expect(R.interpret("1", field: empty, prefill: nil) == .invalid(L("Reply with one of the numbers below.")))
        #expect(R.interpret("2026-03-01", field: date, prefill: nil) == .value(.string("2026-03-01")))
        #expect(R.interpret("someday", field: date, prefill: nil) == .invalid(L("Reply with a date, like 2026-03-01.")))
        #expect(R.interpret("skip", field: optional, prefill: nil) == .skip)
        #expect(R.interpret("skip", field: required, prefill: nil) != .skip)
        #expect(R.interpret("keep", field: required, prefill: .string("Acme")) == .value(.string("Acme")))
        #expect(R.interpret("keep", field: required, prefill: nil) == .value(.string("keep")))
        #expect(R.interpret(" Cancel ", field: required, prefill: nil) == .cancel)
        #expect(R.interpret("stop", field: required, prefill: nil) == .value(.string("stop")))
        #expect(R.interpret("   ", field: required, prefill: nil) == .invalid(L("Reply with an answer.")))
    }

    @Test func questionShowsPositionOptionsAndTheDefault() {
        let fields = [
            DialogField(key: "c", label: "Project", type: .choice, options: ["Alpha", "Beta"]),
            DialogField(key: "o", label: "Notes", required: false),
        ]
        let session = ChannelDialogRelay.Session(dialog: Self.dialog(fields, prefill: ["c": .string("Beta")]), fields: fields)
        let question = ChannelDialogRelay.question(session)
        #expect(question.hasPrefix("(1/2) Project"))
        #expect(question.contains("1. Alpha\n2. Beta"))
        #expect(question.contains("Beta"))
        #expect(question.contains("keep"))
        let opening = ChannelDialogRelay.openingText(session.dialog)
        #expect(opening.hasPrefix("New ticket\nA few details"))
        #expect(opening.contains("cancel"))
    }

    // MARK: - Round trip

    @Test func offerAsksThenAnswersFieldByFieldFromTheSender() async {
        let harness = Harness()
        let fields = [
            DialogField(key: "summary", label: "Summary"),
            DialogField(key: "urgent", label: "Urgent", type: .bool),
        ]
        let dialog = Self.dialog(fields)
        harness.pending = [dialog.id]
        await harness.relay.offer(dialog)
        #expect(harness.relay.sessions[Self.target.conversationKey] != nil)
        #expect(await harness.texts().first?.contains("(1/2) Summary") == true)

        #expect(!harness.relay.awaitsAnswer(from: Self.message("me too", sender: "u-2")))
        #expect(await harness.relay.consume(Self.message("me too", sender: "u-2")) == nil)

        let first = await harness.relay.consume(Self.message("Printer is down"))
        #expect(first == .fired(eventNames: ["Intake"], rule: "dialog_answer"))
        #expect(await harness.texts().last?.contains("(2/2) Urgent") == true)

        let invalid = await harness.relay.consume(Self.message("maybe"))
        #expect(invalid == .fired(eventNames: ["Intake"], rule: "dialog_invalid"))

        let last = await harness.relay.consume(Self.message("yes"))
        #expect(last == .fired(eventNames: ["Intake"], rule: "dialog_answered"))
        #expect(harness.answered.count == 1)
        #expect(harness.answered.first?.0 == dialog.id)
        #expect(harness.answered.first?.1 == ["summary": .string("Printer is down"), "urgent": .bool(true)])
        #expect(harness.relay.sessions.isEmpty)
        #expect(!harness.relay.awaitsAnswer(from: Self.message("thanks")))
    }

    @Test func cancelDismissesTheForm() async {
        let harness = Harness()
        let dialog = Self.dialog([DialogField(key: "summary", label: "Summary")])
        harness.pending = [dialog.id]
        await harness.relay.offer(dialog)
        let result = await harness.relay.consume(Self.message("cancel"))
        #expect(result == .fired(eventNames: ["Intake"], rule: "dialog_cancelled"))
        #expect(harness.dismissed == [dialog.id])
        #expect(harness.answered.isEmpty)
        #expect(harness.relay.sessions.isEmpty)
    }

    @Test func answeredOnTheMacFirstLetsTheMessageThrough() async {
        let harness = Harness()
        let dialog = Self.dialog([DialogField(key: "summary", label: "Summary")])
        harness.pending = [dialog.id]
        await harness.relay.offer(dialog)
        harness.pending = []
        #expect(await harness.relay.consume(Self.message("late answer")) == nil)
        #expect(harness.relay.sessions.isEmpty)
    }

    @Test func formsAChatCannotCarryAreSentToTheMacAndTestRunsAreNotAsked() async {
        let harness = Harness()
        let secret = Self.dialog([DialogField(key: "token", label: "Token", type: .secret)])
        await harness.relay.offer(secret)
        await harness.relay.offer(secret)
        #expect(await harness.texts() == [ChannelDialogRelay.answerOnMacText(secret)], "told once")
        #expect(harness.relay.sessions.isEmpty)

        let test = Self.dialog([DialogField(key: "summary", label: "Summary")], kind: .test)
        await harness.relay.offer(test)
        #expect(await harness.texts().count == 1)
    }

    @Test func aRejectedAnswerPointsToTheMac() async {
        let harness = Harness(answerResult: .failure(.invalid(["summary is too long"])))
        let dialog = Self.dialog([DialogField(key: "summary", label: "Summary")])
        harness.pending = [dialog.id]
        await harness.relay.offer(dialog)
        let result = await harness.relay.consume(Self.message("x"))
        #expect(result == .fired(eventNames: ["Intake"], rule: "dialog_invalid"))
        #expect(await harness.texts().last?.contains("summary is too long") == true)
        await harness.relay.offer(dialog)
        #expect(harness.relay.sessions.isEmpty, "not asked again")
    }

    // MARK: - Safety

    @Test func aSenderThePlatformDidNotNameIsSentToTheMac() async {
        let harness = Harness()
        var anonymous = Self.target
        anonymous.senderId = nil
        let dialog = PendingDialog(
            id: UUID(), runID: UUID(), workflowID: UUID(), workflowName: "Intake", nodeID: "ask",
            title: "New ticket", message: "", fields: [DialogField(key: "summary", label: "Summary")], prefill: [:],
            caller: WorkflowCaller(kind: .event, channelReply: anonymous), createdAt: Date())
        await harness.relay.offer(dialog)
        #expect(harness.relay.sessions.isEmpty)
        #expect(await harness.texts() == [ChannelDialogRelay.answerOnMacText(dialog)])
        #expect(!harness.relay.awaitsAnswer(from: Self.message("anyone")))
    }

    @Test func aQuestionLeftADayMovesToTheMacOnce() async {
        let harness = Harness()
        var clock = Date()
        harness.relay.now = { clock }
        let dialog = Self.dialog([DialogField(key: "summary", label: "Summary")])
        harness.pending = [dialog.id]
        await harness.relay.offer(dialog)
        clock = clock.addingTimeInterval(ChannelDialogRelay.sessionLifetime + 60)
        let late = await harness.relay.consume(Self.message("here you go"))
        #expect(late == .fired(eventNames: ["Intake"], rule: "dialog_expired"))
        #expect(await harness.texts().last == ChannelDialogRelay.expiredText(dialog))
        #expect(harness.answered.isEmpty)
        #expect(harness.relay.sessions.isEmpty)
        await harness.relay.offer(dialog)
        #expect(await harness.texts().count == 2, "not asked again")
    }

    @Test func fiveAnswersThatDoNotFitMoveTheFormToTheMac() async {
        let harness = Harness()
        let dialog = Self.dialog([DialogField(key: "n", label: "Count", type: .number)])
        harness.pending = [dialog.id]
        await harness.relay.offer(dialog)
        var rules: [AgentChannelInboundRelaySubmission?] = []
        for _ in 0..<ChannelDialogRelay.maximumInvalidAnswers {
            rules.append(await harness.relay.consume(Self.message("lots")))
        }
        let invalid = AgentChannelInboundRelaySubmission.fired(eventNames: ["Intake"], rule: "dialog_invalid")
        #expect(rules.dropLast().allSatisfy { $0 == invalid })
        #expect(rules.last == .fired(eventNames: ["Intake"], rule: "dialog_invalid_limit"))
        #expect(await harness.texts().last == ChannelDialogRelay.tooManyInvalidText(dialog))
        #expect(harness.relay.sessions.isEmpty)
        #expect(harness.answered.isEmpty)
    }

    @Test func anOpenQuestionSurvivesARelaunch() async throws {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialog-sessions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }
        let fields = [
            DialogField(key: "summary", label: "Summary"),
            DialogField(key: "urgent", label: "Urgent", type: .bool),
        ]
        let before = Harness(storeURL: store)
        let dialog = Self.dialog(fields)
        before.pending = [dialog.id]
        await before.relay.offer(dialog)
        _ = await before.relay.consume(Self.message("Printer is down"))
        #expect(FileManager.default.fileExists(atPath: store.path))

        let after = Harness(storeURL: store)
        #expect(after.relay.savedSessions.map(\.cursor) == [1])
        let resumed = PendingDialog(
            id: UUID(), runID: dialog.runID, workflowID: dialog.workflowID, workflowName: dialog.workflowName,
            nodeID: dialog.nodeID, title: dialog.title, message: dialog.message, fields: fields, prefill: [:],
            caller: dialog.caller, createdAt: Date())
        after.pending = [resumed.id]
        await after.relay.offer(resumed)
        let texts = await after.texts()
        #expect(texts.count == 1)
        #expect(texts.first?.hasPrefix("(2/2) Urgent") == true, "asks the question it was on, without the opening")
        let done = await after.relay.consume(Self.message("yes"))
        #expect(done == .fired(eventNames: ["Intake"], rule: "dialog_answered"))
        #expect(after.answered.first?.0 == resumed.id)
        #expect(after.answered.first?.1 == ["summary": .string("Printer is down"), "urgent": .bool(true)])
        after.relay.dialogResolved(resumed.id)
        #expect(!FileManager.default.fileExists(atPath: store.path), "nothing left to save")
    }

    @Test func aFormToldToGoToTheMacStaysThereAfterARelaunch() async {
        let store = FileManager.default.temporaryDirectory
            .appendingPathComponent("dialog-sessions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: store) }
        let secret = Self.dialog([DialogField(key: "token", label: "Token", type: .secret)])
        await Harness(storeURL: store).relay.offer(secret)
        let after = Harness(storeURL: store)
        let resumed = PendingDialog(
            id: UUID(), runID: secret.runID, workflowID: secret.workflowID, workflowName: secret.workflowName,
            nodeID: secret.nodeID, title: secret.title, message: "", fields: secret.fields, prefill: [:],
            caller: secret.caller, createdAt: Date())
        await after.relay.offer(resumed)
        #expect(await after.texts().isEmpty, "told once, before the relaunch")
    }

    @Test func anAnswerInAGroupFollowsTheRulesMentionGate() async throws {
        let ledger = EventRunDatabase()
        try ledger.openInMemory()
        let manager = EventManager(ledger: ledger, persistsToDisk: false)
        let event = manager.create(
            OsaurusEvent(
                name: "Intake",
                source: .channelMessage(
                    ChannelMessageSourceConfig(
                        kind: .slack, connectionId: "slack", requireMention: true, continueThreads: false)),
                action: .workflow(WorkflowEventAction(workflowID: UUID()))))
        let target = WorkflowChannelReplyTarget(
            connectionId: "slack", kind: .slack, conversationId: "C-1", senderId: "U1")
        let harness = Harness()
        let dialog = PendingDialog(
            id: UUID(), runID: UUID(), workflowID: UUID(), workflowName: "Intake", nodeID: "ask",
            title: "New ticket", message: "", fields: [DialogField(key: "summary", label: "Summary")], prefill: [:],
            caller: WorkflowCaller(kind: .event, eventID: event.id, channelReply: target), createdAt: Date())
        await harness.relay.offer(dialog)

        let message = ChannelInboundMessage(
            identity: ChannelIdentity(
                kind: .slack, installationId: "slack", groupId: "C-1", sender: ChannelSenderMetadata(senderId: "U1")),
            kind: .slack, connectionId: "slack", providerEventId: "Ev-1",
            providerRoute: AgentChannelProviderRoute(conversationId: "C-1"), content: "Printer", sourceLabel: "Slack")
        func facts(mentioned: Bool?) -> EventMatcher.ChannelFacts {
            EventMatcher.ChannelFacts(
                kind: .slack, connectionId: "slack", roomId: "C-1", content: "Printer", mentionsBot: mentioned,
                hasPriorOutbound: true)
        }
        #expect(harness.relay.askingEventID(for: message) == event.id)
        #expect(!manager.answerPassesMentionGate(message, facts: facts(mentioned: false), relay: harness.relay))
        #expect(manager.answerPassesMentionGate(message, facts: facts(mentioned: true), relay: harness.relay))
        #expect(manager.answerPassesMentionGate(message, facts: facts(mentioned: nil), relay: harness.relay))
        #expect(manager.answerPassesMentionGate(message, facts: facts(mentioned: false), relay: Harness().relay))
    }
}
