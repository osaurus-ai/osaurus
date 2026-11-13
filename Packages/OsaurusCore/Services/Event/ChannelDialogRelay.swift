//
//  ChannelDialogRelay.swift
//  osaurus
//
//  Asks a workflow's form in the channel conversation that started the run.
//  When a channel-triggered run reaches a dialog, the question goes into
//  the chat one field at a time; the sender's next messages in that
//  conversation answer it instead of starting another run. Only the person
//  whose message started the run can answer. Text, number, yes/no, choice,
//  and date fields work over a channel; a form with a required secret,
//  file, or folder field is answered on the Mac (optional ones are left
//  out), and so is one whose sender the platform did not name. The form
//  stays on the Mac either way, so whoever answers first wins. "cancel"
//  dismisses the form. A question left a day, or answered wrong five
//  times, moves to the Mac. Open questions are saved, so a run resumed
//  after a relaunch asks the next question instead of starting over.
//

import Foundation

@MainActor
final class ChannelDialogRelay {
    static let shared = ChannelDialogRelay(
        storeURL: OsaurusPaths.config().appendingPathComponent("channel-dialog-sessions.json"))

    /// How long a question waits in the chat before it moves to the Mac.
    static let sessionLifetime: TimeInterval = 24 * 3600
    /// Answers that did not fit before the question moves to the Mac.
    static let maximumInvalidAnswers = 5

    struct Session: Sendable {
        var dialog: PendingDialog
        /// The fields asked over the channel, in form order.
        var fields: [DialogField]
        var cursor: Int = 0
        var collected: [String: JSONValue] = [:]
        var askedAt = Date()
        var invalidAnswers = 0

        var current: DialogField { fields[cursor] }
    }

    /// A session as saved between launches. The form comes back under a
    /// new id when its run resumes, so it is matched by run and step.
    struct SavedSession: Codable, Equatable, Sendable {
        var conversationKey: String
        var dialogID: UUID
        var runID: UUID
        var nodeID: String
        var fieldKeys: [String]
        var cursor: Int
        var collected: [String: JSONValue]
        var askedAt: Date
        var invalidAnswers: Int
    }

    /// A form told to be answered on the Mac.
    struct DeclinedDialog: Codable, Hashable, Sendable {
        var dialogID: UUID
        var runID: UUID
        var nodeID: String

        init(_ dialog: PendingDialog) {
            dialogID = dialog.id
            runID = dialog.runID
            nodeID = dialog.nodeID
        }

        func matches(_ dialog: PendingDialog) -> Bool {
            dialogID == dialog.id || (runID == dialog.runID && nodeID == dialog.nodeID)
        }
    }

    private struct SavedState: Codable {
        var sessions: [SavedSession]
        var declined: [DeclinedDialog]
    }

    /// What a message means for the field being asked.
    enum Interpretation: Equatable {
        case value(JSONValue)
        case skip
        case cancel
        case invalid(String)
    }

    /// Open questions by conversation (`WorkflowChannelReplyTarget.conversationKey`).
    private(set) var sessions: [String: Session] = [:] {
        didSet { save() }
    }
    /// Dialogs already told to be answered on the Mac.
    private var declined: Set<DeclinedDialog> = [] {
        didSet { save() }
    }
    /// Sessions a previous launch left open, waiting for their run to ask
    /// the form again.
    private var restorable: [SavedSession] = [] {
        didSet { save() }
    }
    /// Where sessions are saved; nil keeps them in memory (tests).
    private let storeURL: URL?

    /// Posts into the dialog's conversation without standing in for the
    /// workflow's reply. Replaced in tests.
    var sendText: @Sendable (String, PendingDialog) async -> WorkflowChannelReplier.Delivery = { text, dialog in
        await WorkflowChannelReplier.live.send(text, runID: dialog.runID, caller: dialog.caller, marksReplied: false)
    }
    /// The forms waiting now, heads of each workflow's queue first.
    var presentable: () -> [PendingDialog] = { DialogCoordinator.shared.presentable }
    var isPending: (UUID) -> Bool = { id in DialogCoordinator.shared.pending.contains { $0.id == id } }
    var answer: ([String: JSONValue], UUID) -> Result<Void, DialogAnswerError> = { values, id in
        DialogCoordinator.shared.answer(id, values: values)
    }
    var dismiss: (UUID) -> Void = { DialogCoordinator.shared.dismiss($0) }
    var now: () -> Date = { Date() }

    /// `runIsOpen` drops saved sessions of runs that ended meanwhile.
    init(
        storeURL: URL? = nil,
        runIsOpen: (UUID) -> Bool = { id in WorkflowRunStore.shared.run(id: id).map { !$0.status.isTerminal } ?? false }
    ) {
        self.storeURL = storeURL
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
            let state = try? Self.decoder.decode(SavedState.self, from: data)
        else { return }
        restorable = state.sessions.filter { runIsOpen($0.runID) }
        declined = Set(state.declined.filter { runIsOpen($0.runID) })
    }

    // MARK: - Saving

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// What a relaunch would pick up: open sessions and those still
    /// waiting to be re-attached.
    var savedSessions: [SavedSession] {
        let open = sessions.map { key, session in
            SavedSession(
                conversationKey: key, dialogID: session.dialog.id, runID: session.dialog.runID,
                nodeID: session.dialog.nodeID, fieldKeys: session.fields.map(\.key), cursor: session.cursor,
                collected: session.collected, askedAt: session.askedAt, invalidAnswers: session.invalidAnswers)
        }
        return (open + restorable).sorted { $0.askedAt < $1.askedAt }
    }

    private func save() {
        guard let storeURL else { return }
        let state = SavedState(
            sessions: savedSessions, declined: declined.sorted { $0.dialogID.uuidString < $1.dialogID.uuidString })
        if state.sessions.isEmpty, state.declined.isEmpty {
            try? FileManager.default.removeItem(at: storeURL)
            return
        }
        guard let data = try? Self.encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: - Dialog lifecycle

    func dialogPresented(_ dialog: PendingDialog) {
        guard dialog.caller.channelReply != nil else { return }
        Task { await offerPresentable() }
    }

    func dialogResolved(_ id: UUID) {
        declined = declined.filter { $0.dialogID != id }
        sessions = sessions.filter { $0.value.dialog.id != id }
        // A form behind the one just answered may be next in line.
        if presentable().contains(where: { $0.caller.channelReply != nil }) {
            Task { await offerPresentable() }
        }
    }

    /// Asks every presentable channel form whose conversation has no open
    /// question yet.
    func offerPresentable() async {
        for dialog in presentable() where dialog.caller.channelReply != nil {
            await offer(dialog)
        }
    }

    func offer(_ dialog: PendingDialog) async {
        guard !dialog.isTest, let target = dialog.caller.channelReply else { return }
        let key = target.conversationKey
        guard sessions[key] == nil, !sessions.values.contains(where: { $0.dialog.id == dialog.id }) else { return }
        if let index = declined.firstIndex(where: { $0.matches(dialog) }) {
            // Told before the relaunch; the resumed form keeps that.
            if declined[index].dialogID != dialog.id {
                declined.remove(at: index)
                declined.insert(DeclinedDialog(dialog))
            }
            return
        }
        // Anyone could answer for a sender the platform did not name.
        guard let fields = Self.channelFields(dialog.fields), target.senderId?.nonEmptyOrNil != nil else {
            declined.insert(DeclinedDialog(dialog))
            _ = await sendText(Self.answerOnMacText(dialog), dialog)
            return
        }
        if let session = restore(dialog, fields: fields) {
            sessions[key] = session
            let delivery = await sendText(Self.question(session), dialog)
            if !delivery.sent {
                sessions[key] = nil
                declined.insert(DeclinedDialog(dialog))
            }
            return
        }
        let session = Session(dialog: dialog, fields: fields, askedAt: now())
        sessions[key] = session
        let delivery = await sendText(Self.openingText(dialog) + "\n\n" + Self.question(session), dialog)
        if !delivery.sent {
            sessions[key] = nil
            declined.insert(DeclinedDialog(dialog))
        }
    }

    /// The session a previous launch saved for this form's run and step,
    /// when it asked the same fields.
    private func restore(_ dialog: PendingDialog, fields: [DialogField]) -> Session? {
        guard
            let index = restorable.firstIndex(where: {
                $0.dialogID == dialog.id || ($0.runID == dialog.runID && $0.nodeID == dialog.nodeID)
            })
        else { return nil }
        let saved = restorable.remove(at: index)
        guard saved.fieldKeys == fields.map(\.key), saved.cursor < fields.count else { return nil }
        return Session(
            dialog: dialog, fields: fields, cursor: saved.cursor, collected: saved.collected, askedAt: saved.askedAt,
            invalidAnswers: saved.invalidAnswers)
    }

    // MARK: - Answers

    /// Whether `message` answers an open question: same conversation, and
    /// the sender is the one whose message started the run.
    func awaitsAnswer(from message: ChannelInboundMessage) -> Bool {
        guard let session = sessions[message.conversationKey],
            let sender = session.dialog.caller.channelReply?.senderId?.nonEmptyOrNil
        else { return false }
        return sender == message.identity.sender.senderId
    }

    /// Takes `message` as the answer to the open question in its
    /// conversation. Nil when there is none, so the message is matched as
    /// usual.
    func consume(_ message: ChannelInboundMessage) async -> AgentChannelInboundRelaySubmission? {
        let key = message.conversationKey
        guard awaitsAnswer(from: message), var session = sessions[key] else { return nil }
        let dialog = session.dialog
        guard isPending(dialog.id) else {
            sessions[key] = nil
            return nil
        }
        let fired = { (rule: String) in
            AgentChannelInboundRelaySubmission.fired(eventNames: [dialog.workflowName], rule: rule)
        }
        if now().timeIntervalSince(session.askedAt) > Self.sessionLifetime {
            sessions[key] = nil
            declined.insert(DeclinedDialog(dialog))
            _ = await sendText(Self.expiredText(dialog), dialog)
            return fired("dialog_expired")
        }
        let field = session.current
        switch Self.interpret(message.content, field: field, prefill: dialog.prefill[field.key]) {
        case .cancel:
            sessions[key] = nil
            dismiss(dialog.id)
            _ = await sendText(L("Stopped. \(dialog.workflowName) will not go on."), dialog)
            return fired("dialog_cancelled")
        case .invalid(let hint):
            session.invalidAnswers += 1
            if session.invalidAnswers >= Self.maximumInvalidAnswers {
                sessions[key] = nil
                declined.insert(DeclinedDialog(dialog))
                _ = await sendText(Self.tooManyInvalidText(dialog), dialog)
                return fired("dialog_invalid_limit")
            }
            sessions[key] = session
            _ = await sendText(hint + "\n\n" + Self.question(session), dialog)
            return fired("dialog_invalid")
        case .skip:
            break
        case .value(let value):
            session.collected[field.key] = value
        }
        session.cursor += 1
        if session.cursor < session.fields.count {
            sessions[key] = session
            _ = await sendText(Self.question(session), dialog)
            return fired("dialog_answer")
        }
        sessions[key] = nil
        switch answer(session.collected, dialog.id) {
        case .success:
            return fired("dialog_answered")
        case .failure(let error):
            declined.insert(DeclinedDialog(dialog))
            _ = await sendText(
                (error.errorDescription ?? L("That answer did not fit the form.")) + "\n"
                    + L("Answer “\(dialog.title)” on the Mac instead."), dialog)
            return fired("dialog_invalid")
        }
    }

    func resetForTesting() {
        sessions.removeAll()
        declined.removeAll()
        restorable.removeAll()
    }

    /// The event whose message started the run asking in this
    /// conversation, so its mention rule applies to the answer too.
    func askingEventID(for message: ChannelInboundMessage) -> UUID? {
        sessions[message.conversationKey]?.dialog.caller.eventID
    }

    // MARK: - Pure

    static let channelFieldTypes: Set<DialogFieldType> = [.text, .longText, .number, .bool, .choice, .date]

    /// The fields to ask over a channel, or nil when the form must be
    /// answered on the Mac (a required field a chat cannot carry, or
    /// nothing a chat can).
    static func channelFields(_ fields: [DialogField]) -> [DialogField]? {
        if fields.contains(where: { $0.required && !channelFieldTypes.contains($0.type) }) { return nil }
        let askable = fields.filter { channelFieldTypes.contains($0.type) }
        return askable.isEmpty ? nil : askable
    }

    static func interpret(_ raw: String, field: DialogField, prefill: JSONValue?) -> Interpretation {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let word = text.lowercased()
        if word == "cancel" { return .cancel }
        if word == "keep", let prefill, prefill != .null { return .value(prefill) }
        if word == "skip" {
            return field.required ? .invalid(L("“\(field.label)” is required.")) : .skip
        }
        guard !text.isEmpty else { return .invalid(L("Reply with an answer.")) }
        switch field.type {
        case .number:
            guard let n = Double(text.replacingOccurrences(of: ",", with: "")) else {
                return .invalid(L("Reply with a number."))
            }
            return .value(.number(n))
        case .bool:
            if ["yes", "y", "true", "on", "1"].contains(word) { return .value(.bool(true)) }
            if ["no", "n", "false", "off", "0"].contains(word) { return .value(.bool(false)) }
            return .invalid(L("Reply yes or no."))
        case .choice:
            let options = field.options ?? []
            if let n = Int(text), n >= 1, n <= options.count { return .value(.string(options[n - 1])) }
            if let match = options.first(where: { $0.lowercased() == word }) { return .value(.string(match)) }
            return .invalid(L("Reply with one of the numbers below."))
        case .date:
            guard WorkflowCondition.date(.string(text)) != nil else {
                return .invalid(L("Reply with a date, like 2026-03-01."))
            }
            return .value(.string(text))
        case .text, .longText:
            return .value(.string(text))
        case .file, .folder, .secret:
            return .invalid(L("Answer this one on the Mac."))
        }
    }

    static func openingText(_ dialog: PendingDialog) -> String {
        var text = dialog.title
        if !dialog.message.isEmpty { text += "\n" + dialog.message }
        return text + "\n" + L("(Reply cancel to stop.)")
    }

    static func question(_ session: Session) -> String {
        let field = session.current
        var lines: [String] = []
        let position = session.fields.count > 1 ? "(\(session.cursor + 1)/\(session.fields.count)) " : ""
        lines.append(position + field.label + (field.required ? "" : " " + L("(optional, reply skip)")))
        switch field.type {
        case .choice:
            for (i, option) in (field.options ?? []).enumerated() { lines.append("\(i + 1). \(option)") }
            lines.append(L("Reply with a number."))
        case .bool: lines.append(L("Reply yes or no."))
        case .number: lines.append(L("Reply with a number."))
        case .date: lines.append(L("Reply with a date, like 2026-03-01."))
        case .text, .longText, .file, .folder, .secret: break
        }
        if let prefill = session.dialog.prefill[field.key], prefill != .null {
            lines.append(L("Reply keep for: \(BindingRenderer.textValue(prefill))"))
        }
        return lines.joined(separator: "\n")
    }

    static func answerOnMacText(_ dialog: PendingDialog) -> String {
        L("\(dialog.workflowName) needs an answer on the Mac: “\(dialog.title)”.")
    }

    static func expiredText(_ dialog: PendingDialog) -> String {
        L("This question was open for a day, so it moved to the Mac: “\(dialog.title)” is still open there.")
    }

    static func tooManyInvalidText(_ dialog: PendingDialog) -> String {
        L("Those answers did not fit. Answer “\(dialog.title)” on the Mac instead.")
    }
}
