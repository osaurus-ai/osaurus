//
//  SyncServedChats.swift
//  osaurus
//
//  Chats a Mac served for a teammate, an invite-link caller or the paired
//  iPhone sync to the user's other devices, tagged `servedBy` with that Mac
//  (osaurus-sync docs/app-data.md, "Served chats"). Only the serving Mac
//  talks to the caller. Owner turns written on another device reach the run
//  through it, and the owner approvals it waits on are published for the
//  other devices to answer. Each namespace has one writer.
//

import Foundation
import OsaurusSync
import os

enum SyncServedChatsContract {
    /// Host: the owner turns from other devices it handed to the run.
    static let deliveryNamespace = "ai.osaurus.served-delivery/1"
    /// Host: the owner approvals the run is waiting on.
    static let approvalNamespace = "ai.osaurus.owner-approval/1"
    /// One per answering device: `<prefix><device key>`.
    static let answerNamespacePrefix = "ai.osaurus.owner-approval-answer/1/"

    static func answerNamespace(device: String) -> String { answerNamespacePrefix + device }

    struct Delivery: Codable, Equatable, Sendable {
        var v: Int = 1
        /// Turn ids (lowercased), oldest first.
        var delivered: [String]
    }

    struct PendingApproval: Codable, Equatable, Sendable {
        var id: String
        var tool: String
        var title: String
        var description: String
        var arguments: String?
        var caller: String?
        var agent: String?
        var offersConversationLease: Bool
        var requestedMs: Int64
        var expiresMs: Int64?
    }

    struct Approvals: Codable, Equatable, Sendable {
        var v: Int = 1
        var pending: [PendingApproval]
    }

    enum Answer: String, Codable, Sendable {
        case approved, denied
        case allowedForConversation = "allowed_for_conversation"

        init?(_ outcome: AttentionResolution.Outcome) {
            switch outcome {
            case .approved: self = .approved
            case .denied: self = .denied
            case .allowedForConversation: self = .allowedForConversation
            case .replied, .dismissed, .timedOut, .abandoned: return nil
            }
        }

        var outcome: AttentionResolution.Outcome {
            switch self {
            case .approved: return .approved
            case .denied: return .denied
            case .allowedForConversation: return .allowedForConversation
            }
        }
    }

    struct AnswerEntry: Codable, Equatable, Sendable {
        var answer: Answer
        var answeredMs: Int64
    }

    struct Answers: Codable, Equatable, Sendable {
        var v: Int = 1
        var answers: [String: AnswerEntry]

        init(answers: [String: AnswerEntry]) {
            self.answers = answers
        }

        /// Answers a newer version spells differently are skipped, not fatal.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            v = try container.decodeIfPresent(Int.self, forKey: .v) ?? 1
            let raw = try container.decodeIfPresent([String: FailableEntry].self, forKey: .answers) ?? [:]
            answers = raw.compactMapValues(\.entry)
        }

        private struct FailableEntry: Decodable {
            let entry: AnswerEntry?
            init(from decoder: Decoder) throws { entry = try? AnswerEntry(from: decoder) }
        }
    }

    static func read<T: Decodable>(_ type: T.Type, _ namespace: String, from conversation: Conversation) -> T? {
        SyncHostedRunContract.read(type, namespace, from: conversation)
    }

    /// The answers each device wrote, keyed by device.
    static func answers(in conversation: Conversation) -> [String: Answers] {
        var result: [String: Answers] = [:]
        for entry in conversation.appData where entry.namespace.hasPrefix(answerNamespacePrefix) {
            let device = String(entry.namespace.dropFirst(answerNamespacePrefix.count))
            guard !device.isEmpty, SyncHostedRunContract.isSigned(entry, byNamespaceDevice: device),
                let decoded = try? JSONDecoder().decode(Answers.self, from: entry.bytes)
            else { continue }
            result[device] = decoded
        }
        return result
    }

    /// The decision to apply for each approval: the earliest answer from a
    /// device in `deviceNames`, with the name of the device that gave it.
    static func firstAnswers(
        _ answers: [String: Answers],
        deviceNames: [String: String]
    ) -> [(id: String, answer: Answer, device: String)] {
        var first: [String: (entry: AnswerEntry, device: String)] = [:]
        for (device, set) in answers {
            guard let name = deviceNames[device] else { continue }
            for (id, entry) in set.answers {
                if let current = first[id], current.entry.answeredMs <= entry.answeredMs { continue }
                first[id] = (entry, name)
            }
        }
        return first.sorted { $0.value.entry.answeredMs < $1.value.entry.answeredMs }
            .map { (id: $0.key, answer: $0.value.entry.answer, device: $0.value.device) }
    }
}

@MainActor
final class SyncServedChats: ObservableObject {
    static let shared = SyncServedChats()
    typealias Contract = SyncServedChatsContract

    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.served")

    /// Owner turns from other devices older than this when the host first
    /// sees them are not delivered.
    nonisolated static let deliveryWindowMs: Int64 = 7 * 24 * 3600 * 1000
    /// How many of a chat's latest messages the host checks for owner turns.
    nonisolated static let scanLimit: UInt32 = 50
    /// Delivered turn ids kept in the record.
    nonisolated static let deliveryRecordLimit = 200

    // MARK: - Ledger

    /// The owner turns this Mac handled, so each is delivered once across launches.
    struct Ledger: Codable, Equatable, Sendable {
        /// Turn id (lowercased) → when it was handled.
        var turns: [String: Int64] = [:]

        static let retentionMs: Int64 = 30 * 24 * 3600 * 1000

        mutating func prune(nowMs: Int64) {
            turns = turns.filter { nowMs - $0.value < Self.retentionMs }
        }
    }

    enum LedgerStore {
        static var url: URL { OsaurusPaths.syncLocalState().appendingPathComponent("served-deliveries.json") }
        static var promotedURL: URL { OsaurusPaths.syncLocalState().appendingPathComponent("served-promoted.json") }

        static func load() -> Ledger {
            guard let data = try? EncryptedFileStore.readPolicyAware(plaintextURL: url),
                let ledger = try? JSONDecoder().decode(Ledger.self, from: data)
            else { return Ledger() }
            return ledger
        }

        static func save(_ ledger: Ledger) {
            write(try JSONEncoder().encode(ledger), to: url)
        }

        static var promoted: Bool { FileManager.default.fileExists(atPath: promotedURL.path) }

        static func markPromoted() {
            write(Data(#"{"v":1}"#.utf8), to: promotedURL)
        }

        private static func write(_ data: @autoclosure () throws -> Data, to url: URL) {
            do {
                try FileManager.default.createDirectory(
                    at: OsaurusPaths.syncLocalState(),
                    withIntermediateDirectories: true
                )
                try EncryptedFileStore.writePolicyAware(data(), toPlaintextURL: url)
            } catch {
                SyncServedChats.log.error("write \(url.lastPathComponent, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - State

    /// On the other devices: the owner turns the serving Mac has delivered, by session.
    @Published private(set) var delivered: [UUID: Set<String>] = [:]

    private struct Mirror {
        let scope: String
        let sessionId: UUID
        var card: OwnerApprovalPromptState?
    }

    private var started = false
    private var promoting = false
    private var observers: [NSObjectProtocol] = []
    private var attentionObserver: UUID?
    private var listSubscription: OsaurusSync.Subscription?
    private var ledger = Ledger()
    private var queued: Set<String> = []
    private var processing: Set<String> = []
    private var flushTask: Task<Void, Never>?
    /// Host: the approvals last written, by scope.
    private var published: [String: [Contract.PendingApproval]] = [:]
    /// Other devices: approvals raised here, by id.
    private var mirrors: [UUID: Mirror] = [:]

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        ledger = LedgerStore.load()
        attentionObserver = AttentionCenter.shared.observe { event in
            let item = event.item
            guard item.kind == .ownerApproval, let sessionId = item.sessionId,
                SyncServedChats.shared.mirrors[item.id] == nil
            else { return }
            SyncServedChats.shared.publishApprovals(sessionId: sessionId)
        }
        observers += SyncService.shared.observeCore(
            attach: { SyncServedChats.shared.subscribe($0) },
            detach: { SyncServedChats.shared.detach() })
    }

    private func detach() {
        listSubscription?.cancel()
        listSubscription = nil
        published.removeAll()
        for id in Array(mirrors.keys) { dropMirror(id) }
    }

    private func subscribe(_ core: SyncCore) {
        detach()
        listSubscription = core.subscribeConversations { changes in
            var served: [String] = []
            for change in changes {
                if case .changed(let conversation) = change,
                    conversation.tag(SyncConversationMapper.TagKey.servedBy) != nil
                {
                    served.append(conversation.scope)
                }
            }
            guard !served.isEmpty else { return }
            Task { @MainActor in
                for scope in served { SyncServedChats.shared.schedule(scope) }
            }
        }
        promoteOnce(core)
        rescan(core)
    }

    private func rescan(_ core: SyncCore) {
        Task { @MainActor in
            let scopes = await Task.detached(priority: .utility) { () -> [String] in
                let filter = ConversationFilter(hasTags: [SyncConversationMapper.TagKey.servedBy])
                return ((try? core.conversationsFiltered(filter: filter)) ?? []).map(\.scope)
            }.value
            for scope in scopes { schedule(scope) }
        }
    }

    /// Served chats from before they synced: promoted once, tagged with this Mac.
    private func promoteOnce(_ core: SyncCore) {
        guard !LedgerStore.promoted, !promoting else { return }
        promoting = true
        Task { @MainActor in
            let count = await Task.detached(priority: .utility) { () -> Int? in
                do {
                    return try Self.promoteServedChats(core: core)
                } catch {
                    Self.log.error("promote failed: \(error.syncLogDetail, privacy: .public)")
                    return nil
                }
            }.value
            promoting = false
            guard let count else { return }
            LedgerStore.markPromoted()
            if count > 0 {
                Self.log.info("promoted \(count, privacy: .public) served chats")
                ChatSessionsManager.shared.refresh()
                rescan(core)
            }
        }
    }

    /// Promotes this device's local `.workspace` conversations to synced and
    /// tags them with it. Returns how many it promoted.
    nonisolated static func promoteServedChats(core: SyncCore) throws -> Int {
        try SyncConversationStore.shared.performWrite { core in
            let filter = ConversationFilter(
                tags: [Tag(key: SyncConversationMapper.TagKey.source, value: SessionSource.workspace.rawValue)],
                replication: .deviceLocal
            )
            let me = core.deviceKey()
            var count = 0
            for conversation in try core.conversationsFiltered(filter: filter) {
                if conversation.tag(SyncConversationMapper.TagKey.servedBy) == nil {
                    let tags = conversation.tags + [Tag(key: SyncConversationMapper.TagKey.servedBy, value: me)]
                    try core.setConversationTags(scope: conversation.scope, tags: tags.sorted { $0.key < $1.key })
                }
                try core.promoteToSynced(scope: conversation.scope)
                count += 1
            }
            if count > 0 { core.syncNow() }
            return count
        }
    }

    private func schedule(_ scope: String) {
        queued.insert(scope)
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            let chats = SyncServedChats.shared
            let scopes = chats.queued
            chats.queued.removeAll()
            chats.flushTask = nil
            for scope in scopes { await chats.process(scope) }
        }
    }

    // MARK: - Processing

    private struct Snapshot: Sendable {
        let me: String
        let conversation: Conversation
        let sessionId: UUID
        /// Other devices of the user that aren't revoked: key → name.
        let deviceNames: [String: String]
        /// Host only: owner turns other devices wrote, oldest first.
        let ownerTurns: [ChatTurnData]
    }

    private func process(_ scope: String) async {
        guard !processing.contains(scope), let core = SyncService.shared.core else { return }
        processing.insert(scope)
        defer { processing.remove(scope) }
        let snapshot = await Task.detached(priority: .userInitiated) { () -> Snapshot? in
            Self.snapshot(scope: scope, core: core)
        }.value
        guard let snapshot else { return }
        if snapshot.conversation.tag(SyncConversationMapper.TagKey.servedBy) == snapshot.me {
            deliver(snapshot)
            applyAnswers(snapshot)
            publishApprovals(sessionId: snapshot.sessionId, against: snapshot.conversation)
        } else {
            let record = Contract.read(Contract.Delivery.self, Contract.deliveryNamespace, from: snapshot.conversation)
            let ids = Set(record?.delivered ?? [])
            if delivered[snapshot.sessionId] != ids { delivered[snapshot.sessionId] = ids }
            reconcileMirrors(snapshot)
        }
    }

    nonisolated private static func snapshot(scope: String, core: SyncCore) -> Snapshot? {
        guard let conversation = try? core.conversation(scope: scope),
            let servedBy = conversation.tag(SyncConversationMapper.TagKey.servedBy),
            conversation.replication == .synced
        else { return nil }
        let me = core.deviceKey()
        var deviceNames: [String: String] = [:]
        for device in (try? core.devices()) ?? [] where !device.isSelf && !device.revoked {
            deviceNames[device.id] = device.name
        }
        var turns: [ChatTurnData] = []
        if servedBy == me, let page = try? core.messages(scope: scope, before: nil, limit: scanLimit) {
            turns = ownerTurns(in: page.messages, me: me, devices: Set(deviceNames.keys), nowMs: SyncHostedRunContract.nowMs())
        }
        return Snapshot(
            me: me,
            conversation: conversation,
            sessionId: SyncConversationMapper.sessionId(of: conversation),
            deviceNames: deviceNames,
            ownerTurns: turns
        )
    }

    /// Owner turns another of the user's devices wrote: user messages,
    /// written as the user, by a device in `devices`, within the delivery window.
    nonisolated static func ownerTurns(in messages: [SyncMessage], me: String, devices: Set<String>, nowMs: Int64)
        -> [ChatTurnData]
    {
        messages.compactMap { message in
            guard message.role == .user, !message.isAgent, message.authorDevice != me,
                devices.contains(message.authorDevice),
                nowMs - Int64(message.timestampMs) <= deliveryWindowMs
            else { return nil }
            let turn = SyncConversationMapper.turn(
                from: message,
                readBlob: { _ in nil },
                materialize: { _, _, _ in nil }
            ).turn
            guard turn.role == .user, let author = turn.author, author.kind == .owner || author.kind == .ownerDevice
            else { return nil }
            return turn
        }
    }

    // MARK: - Host: owner turns

    private func deliver(_ snapshot: Snapshot) {
        let record = Contract.read(Contract.Delivery.self, Contract.deliveryNamespace, from: snapshot.conversation)
        let recorded = Set(record?.delivered ?? [])
        let nowMs = SyncHostedRunContract.nowMs()
        var handled: [String] = []
        for turn in snapshot.ownerTurns {
            let id = turn.id.uuidString.lowercased()
            guard ledger.turns[id] == nil, !recorded.contains(id) else { continue }
            let message = InboundSharedRunBridge.shared.deliverOwnerTurn(sessionId: snapshot.sessionId, turn: turn)
            Self.log.info(
                "owner turn \(id, privacy: .public) from another device \(message == nil ? "not taken" : "delivered", privacy: .public)"
            )
            ledger.turns[id] = nowMs
            handled.append(id)
        }
        guard !handled.isEmpty else { return }
        ledger.prune(nowMs: nowMs)
        LedgerStore.save(ledger)
        let ids = Array(((record?.delivered ?? []) + handled).suffix(Self.deliveryRecordLimit))
        write(scope: snapshot.conversation.scope, namespace: Contract.deliveryNamespace, Contract.Delivery(delivered: ids))
    }

    // MARK: - Host: approvals

    /// Answers from the user's other devices settle the approvals they name:
    /// the earliest wins, and one for an approval that already settled is ignored.
    private func applyAnswers(_ snapshot: Snapshot) {
        let answers = Contract.answers(in: snapshot.conversation)
        guard !answers.isEmpty else { return }
        for decision in Contract.firstAnswers(answers, deviceNames: snapshot.deviceNames) {
            guard let id = UUID(uuidString: decision.id),
                let item = AttentionCenter.shared.pending.first(where: { $0.id == id }),
                item.kind == .ownerApproval, item.sessionId == snapshot.sessionId
            else { continue }
            let resolved = AttentionCenter.shared.resolve(
                id: id,
                with: AttentionResolution(
                    outcome: decision.answer.outcome,
                    surface: .desktop,
                    decidedBy: .ownerDevice(decision.device)
                )
            )
            Self.log.info("approval \(decision.id, privacy: .public) answered on another device: \(resolved, privacy: .public)")
        }
    }

    static func pendingApprovals(sessionId: UUID) -> [Contract.PendingApproval] {
        AttentionCenter.shared.pending.filter { $0.kind == .ownerApproval && $0.sessionId == sessionId }.map { item in
            Contract.PendingApproval(
                id: item.id.uuidString.lowercased(),
                tool: item.toolName ?? "",
                title: item.title,
                description: item.body,
                arguments: OwnerApprovalService.shared.pendingArguments[item.id],
                caller: item.requester.map { ParticipantFormatter.short($0) },
                agent: item.agent?.displayName,
                offersConversationLease: item.actions.contains(.allowForConversation),
                requestedMs: Int64((item.createdAt.timeIntervalSince1970 * 1000).rounded()),
                expiresMs: item.expiresAt.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
            )
        }
    }

    /// Writes the approvals a served chat is waiting on when they changed.
    private func publishApprovals(sessionId: UUID, against conversation: Conversation? = nil) {
        let me = SyncService.shared.core?.deviceKey()
        guard ChatSessionsManager.shared.sessions.first(where: { $0.id == sessionId })?.servedElsewhere(me: me) == nil,
            let scope = SyncConversationStore.shared.scope(forSession: sessionId)
        else { return }
        let pending = Self.pendingApprovals(sessionId: sessionId)
        let current =
            conversation.flatMap { Contract.read(Contract.Approvals.self, Contract.approvalNamespace, from: $0)?.pending }
            ?? published[scope]
        if current == pending || (current == nil && pending.isEmpty) {
            published[scope] = pending
            return
        }
        published[scope] = pending
        write(scope: scope, namespace: Contract.approvalNamespace, Contract.Approvals(pending: pending), servedHereOnly: true)
    }

    // MARK: - Other devices: approvals

    private func reconcileMirrors(_ snapshot: Snapshot) {
        let scope = snapshot.conversation.scope
        let pending =
            Contract.read(Contract.Approvals.self, Contract.approvalNamespace, from: snapshot.conversation)?.pending ?? []
        let mine = Contract.answers(in: snapshot.conversation)[snapshot.me]?.answers ?? [:]
        let open = Set(pending.compactMap { UUID(uuidString: $0.id) })
        for (id, mirror) in mirrors where mirror.scope == scope && !open.contains(id) {
            dropMirror(id)
        }
        let nowMs = SyncHostedRunContract.nowMs()
        for approval in pending {
            guard let id = UUID(uuidString: approval.id), mirrors[id] == nil, mine[approval.id] == nil,
                (approval.expiresMs ?? .max) > nowMs
            else { continue }
            raiseMirror(id: id, approval: approval, scope: scope, sessionId: snapshot.sessionId)
        }
    }

    private func raiseMirror(id: UUID, approval: Contract.PendingApproval, scope: String, sessionId: UUID) {
        let context = ChatSessionsManager.shared.sessions.first(where: { $0.id == sessionId })?.workspace
        let caller = context.map(Participant.caller(from:))
        let expiresAt = approval.expiresMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        var actions: [AttentionAction] = [.approve, .deny, .open]
        if approval.offersConversationLease { actions.insert(.allowForConversation, at: 1) }

        var card: OwnerApprovalPromptState?
        let live = ChatWindowManager.shared.session(forSessionId: sessionId)
        if let live, let caller, let expiresAt {
            let state = OwnerApprovalPromptState(
                attentionId: id,
                caller: caller,
                agentName: approval.agent ?? L("your agent"),
                toolName: approval.tool,
                offersConversationLease: approval.offersConversationLease,
                expiresAt: expiresAt
            )
            live.promptQueue.enqueue(.ownerApproval(state))
            card = state
        }
        mirrors[id] = Mirror(scope: scope, sessionId: sessionId, card: card)
        AttentionCenter.shared.raise(
            AttentionItem(
                id: id,
                kind: .ownerApproval,
                requester: caller,
                agent: approval.agent.map { .agent(name: $0, address: nil) },
                sessionId: sessionId,
                title: approval.title,
                body: approval.description,
                toolName: approval.tool,
                actions: actions,
                createdAt: Date(timeIntervalSince1970: TimeInterval(approval.requestedMs) / 1000),
                expiresAt: expiresAt,
                hasInlineCard: card != nil,
                link: .session(sessionId)
            )
        ) { resolution in
            SyncServedChats.shared.mirrorResolved(id, resolution)
        }
    }

    private func mirrorResolved(_ id: UUID, _ resolution: AttentionResolution) {
        guard let mirror = mirrors.removeValue(forKey: id) else { return }
        settleCard(mirror)
        guard resolution.surface != .system, let answer = Contract.Answer(resolution.outcome) else { return }
        writeAnswer(scope: mirror.scope, approvalId: id.uuidString.lowercased(), answer: answer)
    }

    private func dropMirror(_ id: UUID) {
        guard let mirror = mirrors[id] else { return }
        AttentionCenter.shared.retract(id: id)
        mirrors[id] = nil
        settleCard(mirror)
    }

    private func settleCard(_ mirror: Mirror) {
        guard let card = mirror.card else { return }
        card.settle()
        ChatWindowManager.shared.session(forSessionId: mirror.sessionId)?
            .promptQueue.remove { $0.id == ObjectIdentifier(card) }
    }

    /// Adds this device's answer to its own namespace, keeping only answers
    /// for approvals still waiting.
    private func writeAnswer(scope: String, approvalId: String, answer: Contract.Answer) {
        Task.detached(priority: .userInitiated) {
            do {
                try SyncConversationStore.shared.performWrite { core in
                    guard let conversation = try core.conversation(scope: scope) else { return }
                    let namespace = Contract.answerNamespace(device: core.deviceKey())
                    let open = Set(
                        (Contract.read(Contract.Approvals.self, Contract.approvalNamespace, from: conversation)?.pending
                            ?? []).map(\.id))
                    var answers = Contract.read(Contract.Answers.self, namespace, from: conversation)?.answers ?? [:]
                    answers = answers.filter { open.contains($0.key) }
                    answers[approvalId] = Contract.AnswerEntry(answer: answer, answeredMs: SyncHostedRunContract.nowMs())
                    let bytes = try SyncHostedRunContract.encode(Contract.Answers(answers: answers))
                    try core.setConversationAppData(scope: scope, namespace: namespace, bytes: bytes)
                    core.syncNow()
                }
            } catch {
                Self.log.error("answer write failed: \(error.syncLogDetail, privacy: .public)")
            }
        }
    }

    // MARK: - Other devices: owner turns

    /// Whether the serving Mac has yet to deliver `turn`, an owner turn this device wrote.
    func isAwaitingDelivery(_ turn: ChatTurn, sessionId: UUID) -> Bool {
        guard turn.role == .user, turn.author?.kind == .ownerDevice else { return false }
        return !(delivered[sessionId]?.contains(turn.id.uuidString.lowercased()) ?? false)
    }

    /// The owner writes in a chat another Mac served: the turn joins the
    /// transcript as this device's, and that Mac delivers it.
    @discardableResult
    func postOwnerMessage(sessionId: UUID, text: String) -> ChatTurnData? {
        InboundSharedRunBridge.shared.appendOwnerTurn(
            sessionId: sessionId,
            text: text,
            author: .ownerDevice(SyncService.deviceName)
        )
    }

    // MARK: - Writes

    private func write<T: Encodable & Sendable>(
        scope: String,
        namespace: String,
        _ value: T,
        servedHereOnly: Bool = false
    ) {
        Task.detached(priority: .userInitiated) {
            do {
                let bytes = try SyncHostedRunContract.encode(value)
                try SyncConversationStore.shared.performWrite { core in
                    if servedHereOnly {
                        guard let conversation = try core.conversation(scope: scope),
                            conversation.replication == .synced,
                            conversation.tag(SyncConversationMapper.TagKey.servedBy) == core.deviceKey()
                        else { return }
                    }
                    try core.setConversationAppData(scope: scope, namespace: namespace, bytes: bytes)
                    core.syncNow()
                }
            } catch {
                Self.log.error("\(namespace, privacy: .public) write failed: \(error.syncLogDetail, privacy: .public)")
            }
        }
    }

    #if DEBUG
        func _ledgerForTesting() -> Ledger { ledger }
        var _mirroredIdsForTesting: Set<UUID> { Set(mirrors.keys) }
        var _isAttachedForTesting: Bool { listSubscription != nil }

        /// Runs `process` for `scope` now.
        func _processForTesting(_ scope: String) async {
            await process(scope)
        }

        func _resetForTesting() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            if let attentionObserver { AttentionCenter.shared.removeObserver(attentionObserver) }
            attentionObserver = nil
            listSubscription?.cancel()
            listSubscription = nil
            flushTask?.cancel()
            flushTask = nil
            queued.removeAll()
            processing.removeAll()
            published.removeAll()
            mirrors.removeAll()
            delivered.removeAll()
            ledger = Ledger()
            started = false
            promoting = false
        }
    #endif
}
