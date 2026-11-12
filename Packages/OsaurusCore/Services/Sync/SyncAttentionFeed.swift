//
//  SyncAttentionFeed.swift
//  osaurus
//
//  The iPhone channel of `AttentionCenter`, carried by Sync: while an
//  iPhone is in the account, this Mac keeps what needs the user in its
//  attention conversation (`ai.osaurus.attention/1`) and applies the
//  answers the iPhone writes back (`ai.osaurus.attention-answer/1`).
//  Items the user routed away from the iPhone in Notifications aren't
//  listed.
//

import Combine
import Foundation
import OsaurusSync
import os

@MainActor
final class SyncAttentionFeed {
    static let shared = SyncAttentionFeed()

    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.attention")
    private static let publishDebounce: Duration = .milliseconds(300)

    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var listSubscription: OsaurusSync.Subscription?
    private var publishTask: Task<Void, Never>?
    private var lastPublished: Data?
    /// Answers already applied, by item id, so a re-read doesn't apply twice.
    private var applied: Set<String> = []

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let center = AttentionCenter.shared
        center.$pending.combineLatest(center.$recent)
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { SyncAttentionFeed.shared.schedulePublish() } }
            .store(in: &cancellables)
        SyncPhoneDevices.shared.$hasFeedReader
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { SyncAttentionFeed.shared.schedulePublish() } }
            .store(in: &cancellables)
        observers += SyncService.shared.observeCore(
            attach: { core in
                let feed = SyncAttentionFeed.shared
                feed.subscribe(core)
                feed.lastPublished = nil
                feed.schedulePublish()
            },
            detach: { SyncAttentionFeed.shared.detach() })
    }

    private func detach() {
        listSubscription?.cancel()
        listSubscription = nil
    }

    private func subscribe(_ core: SyncCore) {
        listSubscription?.cancel()
        let me = core.deviceKey()
        listSubscription = core.subscribeConversations { changes in
            let mine = changes.compactMap { change -> Conversation? in
                guard case .changed(let conversation) = change,
                    conversation.tag(SyncConversationMapper.TagKey.kind) == SyncDeviceFeedContract.attentionKind,
                    conversation.tag(SyncConversationMapper.TagKey.device) == me
                else { return nil }
                return conversation
            }
            guard let conversation = mine.last else { return }
            Task { @MainActor in SyncAttentionFeed.shared.applyAnswers(in: conversation) }
        }
    }

    // MARK: - Publishing

    /// The feed's JSON: pending items listed for the iPhone, oldest first,
    /// then recently settled ones. Wire form as `PairedDeviceChannel.wire`.
    static func payload(items: [AttentionItem], recent: [AttentionItem]) -> [String: Any] {
        var budget = detailBudget
        let pending = items.map { item -> [String: Any] in
            var row = PairedDeviceChannel.wire(item)
            let size = item.detail?.count ?? 0
            if row["detail"] != nil {
                if size > budget { row["detail"] = ["truncated": true] } else { budget -= size }
            }
            return row
        }
        return [
            "v": 1,
            "items": pending,
            "recent": recent.prefix(SyncDeviceFeedContract.recentLimit).map(PairedDeviceChannel.wire),
        ]
    }

    /// Detail bytes the whole feed carries, oldest item first; later items
    /// say `truncated` and the iPhone opens the chat for the rest.
    static let detailBudget = 32 * 1024

    func schedulePublish() {
        publishTask?.cancel()
        publishTask = Task { @MainActor in
            try? await Task.sleep(for: Self.publishDebounce)
            guard !Task.isCancelled else { return }
            await publishNow()
        }
    }

    func publishNow() async {
        guard SyncService.shared.core != nil else { return }
        let hasReader = SyncPhoneDevices.shared.hasFeedReader
        let body = Self.payload(
            items: PairedDeviceChannel.shared.feed(),
            recent: Array(AttentionCenter.shared.recent)
        )
        guard let bytes = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]),
            bytes != lastPublished
        else { return }
        let written = await Task.detached(priority: .utility) { () -> Bool in
            do {
                return try SyncConversationStore.shared.performWrite { core in
                    try Self.publish(bytes, core: core, createIfMissing: hasReader)
                }
            } catch SyncConversationStoreError.notOpen {
                return false
            } catch {
                Self.log.error("publish failed: \(error.syncLogDetail, privacy: .public)")
                return false
            }
        }.value
        if written { lastPublished = bytes }
    }

    /// Writes the feed. Without an iPhone in the account nothing is created;
    /// a feed that exists keeps being updated so it empties.
    nonisolated static func publish(_ bytes: Data, core: SyncCore, createIfMissing: Bool) throws -> Bool {
        let me = core.deviceKey()
        let scope: String
        if let existing = try SyncDeviceFeedContract.conversation(
            kind: SyncDeviceFeedContract.attentionKind,
            device: me,
            core: core
        ) {
            if existing.appData(SyncDeviceFeedContract.attentionNamespace) == bytes { return true }
            scope = existing.scope
        } else {
            guard createIfMissing else { return false }
            scope = try SyncDeviceFeedContract.ensureConversation(
                kind: SyncDeviceFeedContract.attentionKind,
                title: String(localized: "Needs You on \(SyncService.deviceName)", bundle: .module),
                core: core
            )
        }
        try core.setConversationAppData(scope: scope, namespace: SyncDeviceFeedContract.attentionNamespace, bytes: bytes)
        core.syncNow()
        return true
    }

    // MARK: - Answers

    func applyAnswers(in conversation: Conversation) {
        let devices = SyncService.shared.devices
        let entries = Self.answers(
            in: conversation,
            deviceNames: SyncDeviceFeedContract.deviceNames(devices),
            legacyLabel: Self.answerLabel(devices: devices)
        )
        guard !entries.isEmpty else { return }
        Self.apply(entries, applied: &applied)
    }

    /// One answer to apply, with the name of the device that gave it.
    struct LabeledAnswer: Equatable, Sendable {
        let id: String
        let answer: SyncDeviceFeedContract.AttentionAnswer
        let deviceLabel: String
    }

    /// Every answer in the conversation, oldest first: each iPhone's own
    /// namespace (named after it, skipped when it isn't in the account), and
    /// the shared one older iPhone builds write.
    static func answers(
        in conversation: Conversation,
        deviceNames: [String: String],
        legacyLabel: String
    ) -> [LabeledAnswer] {
        var entries: [LabeledAnswer] = []
        let perDevice = SyncDeviceFeedContract.perDevice(
            SyncDeviceFeedContract.AttentionAnswers.self,
            prefix: SyncDeviceFeedContract.attentionAnswerNamespacePrefix,
            in: conversation,
            writtenByThatDevice: true
        )
        for (device, set) in perDevice {
            guard let name = deviceNames[device] else { continue }
            entries += set.answers.map { LabeledAnswer(id: $0.key, answer: $0.value, deviceLabel: name) }
        }
        if let legacy = SyncHostedRunContract.read(
            SyncDeviceFeedContract.AttentionAnswers.self,
            SyncDeviceFeedContract.attentionAnswerNamespace,
            from: conversation
        ) {
            entries += legacy.answers.map { LabeledAnswer(id: $0.key, answer: $0.value, deviceLabel: legacyLabel) }
        }
        return entries.sorted { ($0.answer.answeredMs, $0.id) < ($1.answer.answeredMs, $1.id) }
    }

    /// Who answers say they're from. Only devices that read the feeds write
    /// answers, and Sync doesn't say which one did: with one in the account
    /// that's its name, with several iPhones "Your iPhone".
    static func answerLabel(devices: [Device]) -> String {
        let readers = devices.filter { !$0.isSelf && !$0.revoked && $0.devicePlatform.usesMacFeeds }
        if readers.count == 1, let name = readers.first?.name, !name.isEmpty { return name }
        return readers.allSatisfy { $0.devicePlatform == .iPhone } ? L("Your iPhone") : L("Your other device")
    }

    /// Resolves each pending item an answer names, once. An answer the item
    /// doesn't offer, or a stale one, is ignored rather than coerced.
    static func apply(
        _ answers: [String: SyncDeviceFeedContract.AttentionAnswer],
        applied: inout Set<String>,
        deviceLabel: String,
        center: AttentionCenter = .shared,
        nowMs: Int64 = SyncHostedRunContract.nowMs()
    ) {
        let entries = answers.map { LabeledAnswer(id: $0.key, answer: $0.value, deviceLabel: deviceLabel) }
            .sorted { ($0.answer.answeredMs, $0.id) < ($1.answer.answeredMs, $1.id) }
        apply(entries, applied: &applied, center: center, nowMs: nowMs)
    }

    /// Applies `entries` in order; the first answer to an item wins.
    static func apply(
        _ entries: [LabeledAnswer],
        applied: inout Set<String>,
        center: AttentionCenter = .shared,
        nowMs: Int64 = SyncHostedRunContract.nowMs(),
        answerForm: (UUID, [String: JSONValue]) -> Result<Void, DialogAnswerError> = {
            DialogCoordinator.shared.answer($0, values: $1)
        }
    ) {
        for entry in entries where !applied.contains(entry.id) {
            let id = entry.id
            let answer = entry.answer
            let deviceLabel = entry.deviceLabel
            // A workflow form filled in on the iPhone: its values go to the form as the Mac's own
            // form sends them, and the run carries on. Answered, the form's item is retracted.
            if answer.action == SyncDeviceFeedContract.submitAction {
                guard let uuid = UUID(uuidString: id),
                    nowMs - answer.answeredMs < SyncDeviceFeedContract.requestTTLMs
                else { continue }
                guard let item = center.item(id: uuid), item.isPending, item.kind == .workflowDialog else {
                    applied.insert(id)
                    continue
                }
                switch answerForm(uuid, answer.values ?? [:]) {
                case .success, .failure(.notFound):
                    applied.insert(id)
                case .failure(.notCurrent):
                    // Another form of the workflow comes first: this one is applied once it's shown.
                    break
                case .failure(.invalid(let issues)):
                    // Left unapplied, so a corrected answer from the iPhone (same id) still lands.
                    let reasons = issues.joined(separator: "; ")
                    log.notice("workflow form \(id, privacy: .public) not accepted: \(reasons, privacy: .public)")
                }
                continue
            }
            guard let uuid = UUID(uuidString: id), nowMs - answer.answeredMs < SyncDeviceFeedContract.requestTTLMs,
                let outcome = SyncDeviceFeedContract.outcome(for: answer.action)
            else { continue }
            let text = answer.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            if outcome == .replied, text?.isEmpty ?? true { continue }
            if (text?.count ?? 0) > AttentionLimits.textCharacters { continue }
            guard let item = center.item(id: uuid), item.isPending else {
                applied.insert(id)
                continue
            }
            if let action = AttentionAction(rawValue: answer.action), item.kind.isBlocking,
                !item.actions.contains(action)
            {
                continue
            }
            let resolution = AttentionResolution(
                outcome: outcome,
                surface: .phone,
                decidedBy: .ownerDevice(deviceLabel),
                replyText: outcome == .replied ? text : nil,
                redact: item.kind == .privacyReview && outcome == .approved ? answer.redact : nil
            )
            guard AttentionCenter.accepts(resolution, for: item) else { continue }
            applied.insert(id)
            center.resolve(id: uuid, with: resolution)
        }
    }

    #if DEBUG
        func _resetForTesting() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            cancellables.removeAll()
            detach()
            publishTask?.cancel()
            publishTask = nil
            lastPublished = nil
            applied.removeAll()
            started = false
        }
    #endif
}
