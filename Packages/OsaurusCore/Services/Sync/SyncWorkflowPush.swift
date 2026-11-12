//
//  SyncWorkflowPush.swift
//  osaurus
//
//  Workflow notifications on the iPhone (`workflow_push`,
//  docs/SYNC_MOBILE_CONTRACT.md §5.6). Each iPhone that wants them writes a
//  registration on this Mac's manage conversation: a grant for the Osaurus
//  push service (sealed to it, so this Mac never sees the APNs token), a key
//  for what the notification says, and which events it wants. When one of
//  this Mac's runs starts, waits for an answer or ends, this sends each
//  registered iPhone a notification whose text only that iPhone can read.
//
//  Only this Mac's own runs are sent: another Mac of the user sends its
//  own, so none is ever sent twice.
//

import CryptoKit
import Foundation
import OsaurusSync
import os

extension SyncDeviceFeedContract {
    /// iPhone: its push registration, one namespace per iPhone.
    static let pushRegistrationNamespacePrefix = "ai.osaurus.push-registration/1/"

    static func pushRegistrationNamespace(device: String) -> String { pushRegistrationNamespacePrefix + device }

    struct PushRegistration: Codable, Equatable, Sendable {
        var v: Int = 1
        /// The sealed grant from `pushGrant`, base64.
        var grant: String
        var grantId: String
        var expiresMs: Int64
        /// 32 bytes, base64: ChaChaPoly key for what a notification says.
        var contentKey: String
        /// Stays the same across unpairing and pairing again, so an older identity's
        /// registration of the same install is skipped.
        var installId: String
        /// `started`, `awaiting_user`, `completed`, `failed`, `cancelled`, `needs_setup`; kept open.
        var events: [String]
        /// No `started` for runs an iPhone started itself.
        var onlyOthers: Bool?
        var updatedMs: Int64
    }
}

@MainActor
final class SyncWorkflowPush {
    static let shared = SyncWorkflowPush()

    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.push")

    /// The push service. A debug build can point elsewhere with the `SyncPushServiceURL` default.
    nonisolated static var serviceURL: URL {
        #if DEBUG
            if let custom = UserDefaults.standard.string(forKey: "SyncPushServiceURL"), let url = URL(string: custom) {
                return url
            }
        #endif
        return URL(string: "https://push.sync.osaurus.ai")!
    }

    /// An iPhone's registration, ready to send with.
    struct Target: Equatable, Sendable {
        var device: String
        var registration: SyncDeviceFeedContract.PushRegistration
        var grant: Data
        var contentKey: Data
    }

    /// What happened to a run, for the notification.
    struct Event: Equatable, Sendable {
        /// One of the registration's `events`, or `cleared` (no longer waiting for an answer).
        var kind: String
        var runId: String
        var workflowId: String
        var name: String
        var error: String?
    }

    private(set) var targets: [Target] = []
    /// The iPhones registered, for the manage state (`pushRegistered`).
    private(set) var registeredDevices: [String] = []
    /// Each run's status when last seen; nil until the first runs list.
    private var lastStatus: [String: String]?
    /// Runs that started or ended before this are history, not news.
    private let sinceMs = SyncHostedRunContract.nowMs()
    /// Runs an iPhone started (`runWorkflow`).
    private var startedFromPhone: Set<String> = []
    /// No sends until then: the service asked to wait.
    private var waitUntilMs: Int64 = 0
    private var refreshTask: Task<Void, Never>?

    private init() {}

    // MARK: Registrations

    func noteStartedFromPhone(_ runId: UUID) {
        startedFromPhone.insert(runId.uuidString.lowercased())
    }

    /// Reads the registrations again (the manage conversation changed, a device came or went).
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            guard let core = SyncService.shared.core else { return }
            let live = Set(SyncService.shared.devices.filter { !$0.isSelf && !$0.revoked }.map(\.id))
            let dropped = DroppedGrants.load(nowMs: SyncHostedRunContract.nowMs())
            let targets = await Task.detached(priority: .utility) {
                Self.targets(core: core, live: live, dropped: dropped, nowMs: SyncHostedRunContract.nowMs())
            }.value
            guard !Task.isCancelled else { return }
            self.targets = targets
            let devices = targets.map(\.device).sorted()
            if devices != registeredDevices {
                registeredDevices = devices
                Self.trace("\(devices.count) iPhones registered")
                SyncManageFeed.shared.schedulePublish()
            }
        }
    }

    /// The registrations on every manage conversation of this Mac (an old one can still be tagged
    /// with it), of devices still in the account, with grants that work: the newest per install.
    nonisolated static func targets(core: SyncCore, live: Set<String>, dropped: Set<String>, nowMs: Int64) -> [Target] {
        let filter = ConversationFilter(
            tags: [
                Tag(key: SyncConversationMapper.TagKey.kind, value: SyncDeviceFeedContract.manageKind),
                Tag(key: SyncConversationMapper.TagKey.device, value: core.deviceKey()),
            ],
            limit: 10
        )
        let conversations = (try? core.conversationsFiltered(filter: filter)) ?? []
        var found: [(String, SyncDeviceFeedContract.PushRegistration)] = []
        for conversation in conversations {
            let byDevice = SyncDeviceFeedContract.perDevice(
                SyncDeviceFeedContract.PushRegistration.self,
                prefix: SyncDeviceFeedContract.pushRegistrationNamespacePrefix,
                in: conversation
            )
            found += byDevice.map { ($0.key, $0.value) }
        }
        return choose(found, live: live, dropped: dropped, nowMs: nowMs)
    }

    nonisolated static func choose(
        _ found: [(String, SyncDeviceFeedContract.PushRegistration)],
        live: Set<String>,
        dropped: Set<String>,
        nowMs: Int64
    ) -> [Target] {
        var newest: [String: Target] = [:]
        for (device, registration) in found where live.contains(device) {
            guard registration.expiresMs > nowMs, !dropped.contains(registration.grantId),
                let grant = Data(base64Encoded: registration.grant),
                let key = Data(base64Encoded: registration.contentKey), key.count == 32
            else { continue }
            // One per install: a phone that unpaired and paired again has an older identity too.
            let install = registration.installId.isEmpty ? device : registration.installId
            if let kept = newest[install], kept.registration.updatedMs >= registration.updatedMs { continue }
            newest[install] = Target(device: device, registration: registration, grant: grant, contentKey: key)
        }
        return newest.values.sorted { $0.device < $1.device }
    }

    // MARK: Runs

    /// Called with each runs list the runs feed computes.
    func observe(_ runs: [SyncDeviceFeedContract.WorkflowRunEntry]) {
        let (events, next) = Self.events(previous: lastStatus, runs: runs, sinceMs: sinceMs)
        lastStatus = next
        guard !events.isEmpty, !targets.isEmpty else { return }
        let nowMs = SyncHostedRunContract.nowMs()
        guard nowMs >= waitUntilMs else {
            Self.trace("\(events.count) events not sent: waiting for the service")
            return
        }
        for event in events {
            for target in targets where Self.wants(target.registration, event, fromPhone: startedFromPhone) {
                send(event, to: target)
            }
        }
    }

    /// The changes between two runs lists worth a notification, and the statuses to compare with
    /// next time. Runs already ended, or started, before `sinceMs` are history.
    nonisolated static func events(
        previous: [String: String]?,
        runs: [SyncDeviceFeedContract.WorkflowRunEntry],
        sinceMs: Int64
    ) -> ([Event], [String: String]) {
        var next: [String: String] = [:]
        var events: [Event] = []
        for run in runs {
            let status = run.card.status
            next[run.card.runId] = status
            let before = previous?[run.card.runId]
            guard before != status else { continue }
            if before == nil, (run.finishedMs ?? run.startedMs) < sinceMs { continue }
            let kind: String
            switch status {
            case "running":
                if before == nil {
                    kind = "started"
                } else if before == "awaiting_user" {
                    kind = "cleared"
                } else {
                    continue
                }
            case "awaiting_user", "completed", "failed", "cancelled", "needs_setup":
                kind = status
            default:
                continue
            }
            events.append(
                Event(
                    kind: kind, runId: run.card.runId, workflowId: run.workflowId, name: run.card.name,
                    error: run.card.error))
        }
        return (events, next)
    }

    nonisolated static func wants(
        _ registration: SyncDeviceFeedContract.PushRegistration,
        _ event: Event,
        fromPhone: Set<String>
    ) -> Bool {
        // Clearing follows the wait it clears.
        let kind = event.kind == "cleared" ? "awaiting_user" : event.kind
        guard registration.events.contains(kind) else { return false }
        if event.kind == "started", registration.onlyOthers ?? true, fromPhone.contains(event.runId) { return false }
        return true
    }

    // MARK: Sending

    private func send(_ event: Event, to target: Target) {
        let macName = SyncService.deviceName
        let text = Self.text(event, macName: macName)
        Task.detached(priority: .utility) {
            guard let core = SyncService.shared.core else { return }
            let outcome = await Self.deliver(event, text: text, to: target, core: core)
            await MainActor.run { SyncWorkflowPush.shared.handle(outcome, event: event, target: target) }
        }
    }

    enum Outcome: Equatable, Sendable {
        case sent
        /// The grant won't work again: refused, expired, revoked, or the app's token is gone.
        case dropGrant(String)
        case wait(seconds: Int)
        case retry
        case failed(String)
    }

    private func handle(_ outcome: Outcome, event: Event, target: Target) {
        switch outcome {
        case .sent:
            Self.trace("sent \(event.kind) for \(event.runId.prefix(8)) to \(target.device.prefix(8))")
        case .dropGrant(let why):
            Self.log.info("push grant dropped: \(why, privacy: .public)")
            Self.trace("grant of \(target.device.prefix(8)) dropped: \(why)")
            DroppedGrants.add(target.registration.grantId, expiresMs: target.registration.expiresMs)
            refresh()
        case .wait(let seconds):
            waitUntilMs = SyncHostedRunContract.nowMs() + Int64(seconds) * 1000
            Self.trace("waiting \(seconds) s before sending again")
        case .retry:
            let text = Self.text(event, macName: SyncService.deviceName)
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(30))
                guard let core = SyncService.shared.core else { return }
                let outcome = await Self.deliver(event, text: text, to: target, core: core)
                if outcome != .sent {
                    Self.log.error("push not sent after a retry")
                    Self.trace("retry failed for \(event.runId.prefix(8)): \(outcome)")
                }
            }
        case .failed(let why):
            Self.log.error("push not sent: \(why, privacy: .public)")
            Self.trace("not sent: \(why)")
        }
    }

    /// The title and body an iPhone shows.
    nonisolated static func text(_ event: Event, macName: String) -> (title: String, body: String) {
        let title = event.name.isEmpty ? L("Workflow") : String(event.name.prefix(100))
        let body: String
        switch event.kind {
        case "started": body = L("Started on \(macName)")
        case "awaiting_user": body = L("Waiting for your answer")
        case "completed": body = L("Finished")
        case "failed":
            let reason = event.error.map { String($0.prefix(200)) }
            body = reason.map { L("Failed") + ": " + $0 } ?? L("Failed")
        case "cancelled": body = L("Stopped")
        case "needs_setup": body = L("Needs setup on \(macName)")
        default: body = ""
        }
        return (title, body)
    }

    /// The APNs payload: a plain fallback alert, and the real text sealed with the iPhone's key
    /// for its notification service extension. A background push carries only the sealed part.
    nonisolated static func payload(
        _ event: Event,
        text: (title: String, body: String),
        key: Data,
        macDevice: String
    ) throws -> Data {
        let content: [String: Any] = [
            "v": 1,
            "event": event.kind,
            "runId": event.runId,
            "workflowId": event.workflowId,
            "device": macDevice,
            "title": text.title,
            "body": text.body,
        ]
        let plain = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        let sealed = try ChaChaPoly.seal(plain, using: SymmetricKey(data: key)).combined.base64EncodedString()
        var aps: [String: Any]
        if event.kind == "cleared" {
            aps = ["content-available": 1]
        } else {
            aps = [
                "alert": ["title": L("Workflow update"), "body": L("Open Osaurus to see it.")],
                "mutable-content": 1,
                "sound": "default",
                "thread-id": event.workflowId,
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["aps": aps, "o": sealed], options: [.sortedKeys])
    }

    nonisolated static func deliver(
        _ event: Event,
        text: (title: String, body: String),
        to target: Target,
        core: SyncCore
    ) async -> Outcome {
        do {
            let payload = try payload(event, text: text, key: target.contentKey, macDevice: core.deviceKey())
            guard payload.count <= 4096 else { return .failed("payload over 4 KB") }
            let body = try core.pushSendRequest(
                grant: target.grant,
                kind: event.kind == "cleared" ? .background : .alert,
                collapseId: event.kind == "cleared" ? nil : event.runId,
                payload: payload
            )
            var request = URLRequest(url: serviceURL.appendingPathComponent("v1/send"))
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.upload(for: request, from: body)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
            switch status {
            case 200: return .sent
            case 403, 410: return .dropGrant(code.isEmpty ? "\(status)" : code)
            case 429:
                let after = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
                return .wait(seconds: max(after ?? 60, 1))
            case 500 ..< 600: return .retry
            default: return .failed("\(status) \(code)")
            }
        } catch let error as URLError {
            return error.code == .notConnectedToInternet ? .failed("offline") : .retry
        } catch {
            return .failed(error.syncLogDetail)
        }
    }

    /// Debug builds: to the console, so `tmp/osaurus.log` has it. Never tokens, grants or keys.
    nonisolated private static func trace(_ line: @autoclosure () -> String) {
        #if DEBUG
            print("[SyncPush] \(line())")
        #endif
    }
}

/// Grants the service refused for good, until they'd have expired anyway, so they aren't tried
/// again while the iPhone's registration still lists them.
enum DroppedGrants {
    private static let key = "SyncPushDroppedGrants"

    static func load(nowMs: Int64) -> Set<String> {
        let all = UserDefaults.standard.dictionary(forKey: key) as? [String: Int64] ?? [:]
        return Set(all.filter { $0.value > nowMs }.keys)
    }

    static func add(_ grantId: String, expiresMs: Int64) {
        let nowMs = SyncHostedRunContract.nowMs()
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int64] ?? [:]).filter { $0.value > nowMs }
        all[grantId] = expiresMs
        UserDefaults.standard.set(all, forKey: key)
    }
}
