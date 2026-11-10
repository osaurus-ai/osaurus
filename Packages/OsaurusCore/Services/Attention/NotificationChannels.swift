//
//  NotificationChannels.swift
//  osaurus
//
//  The delivery side of `AttentionCenter`: one channel per place a person
//  can be reached. Desktop lives in `DesktopNotificationChannel.swift`.
//
//  - In-app: a toast that opens the conversation, plus the Tasks badge.
//  - iPhone: the Sync attention feed (`SyncAttentionFeed`). Delivery is
//    "the item is listed"; the iPhone answers through Sync.
//  - Push: a content-free wake-up per registered device token through a
//    `PushTransport`. No transport ships yet (`NoopPushTransport`), so the
//    channel only records what it would have sent.
//

import Foundation
import os

@MainActor
protocol NotificationChannel: AnyObject {
    var id: NotificationChannelID { get }
    /// Static capability: which kinds this channel can carry at all.
    func supports(_ kind: AttentionKind) -> Bool
    /// Runtime gating (focus, missing transport). Called after preferences.
    func shouldDeliver(_ item: AttentionItem) -> Bool
    func deliver(_ item: AttentionItem)
    func retract(_ item: AttentionItem)
}

extension NotificationChannel {
    func supports(_ kind: AttentionKind) -> Bool { true }
    func shouldDeliver(_ item: AttentionItem) -> Bool { true }
}

// MARK: - In-app

@MainActor
final class InAppAttentionChannel: NotificationChannel {
    static let shared = InAppAttentionChannel()

    let id = NotificationChannelID.inApp
    private var toasts: [UUID: UUID] = [:]

    func shouldDeliver(_ item: AttentionItem) -> Bool {
        // The person is already looking at the card.
        if let sessionId = item.sessionId, ChatWindowManager.shared.isSessionFrontmost(sessionId) { return false }
        return true
    }

    func deliver(_ item: AttentionItem) {
        ManagementBadgeStore.shared.refreshNow()
        // The tool permission panel is its own floating window.
        guard item.kind != .toolApproval else { return }
        let action: ToastAction =
            item.sessionId.map { .openChatSession(sessionId: $0, agentId: item.agentId) }
            ?? .openSettings(tab: (item.kind.isBlocking ? ManagementTab.approvals : .insights).rawValue)
        let toast = ToastManager.shared.action(
            item.title,
            message: item.body.isEmpty ? nil : item.body,
            action: action,
            buttonTitle: item.sessionId == nil ? L("Open") : L("Open Chat"),
            timeout: item.kind.isBlocking ? 0 : 8
        )
        toasts[item.id] = toast
        let itemId = item.id
        let blocking = item.kind.isBlocking
        ToastManager.shared.onDismiss(of: toast) { [weak self] reason in
            self?.toasts.removeValue(forKey: itemId)
            // Closing a notice, or opening it, dismisses it everywhere. A
            // notice that only timed out stays on the phone.
            guard !blocking else { return }
            switch reason {
            case .user, .action: AttentionCenter.shared.retract(id: itemId)
            case .expired, .programmatic: break
            }
        }
    }

    func retract(_ item: AttentionItem) {
        if let toast = toasts.removeValue(forKey: item.id) { ToastManager.shared.dismiss(id: toast) }
        ManagementBadgeStore.shared.refreshNow()
    }
}

// MARK: - iPhone feed

@MainActor
final class PairedDeviceChannel: NotificationChannel {
    static let shared = PairedDeviceChannel()

    let id = NotificationChannelID.phone
    /// Items listed on the iPhone's feed.
    private(set) var listed: Set<UUID> = []

    func deliver(_ item: AttentionItem) {
        listed.insert(item.id)
        SyncAttentionFeed.shared.schedulePublish()
    }

    func retract(_ item: AttentionItem) {
        listed.remove(item.id)
        SyncAttentionFeed.shared.schedulePublish()
    }

    /// Pending items the iPhone should show, oldest first.
    func feed(center: AttentionCenter = .shared) -> [AttentionItem] {
        center.pending.filter { listed.contains($0.id) }
    }

    /// Longest tool-argument preview the iPhone is sent.
    static let argumentsPreviewLimit = 512

    /// The wire form of one item (docs/SYNC_MOBILE_CONTRACT.md). The iPhone
    /// is the owner's, so title, body and a pending tool call's arguments
    /// are included, so the owner sees what they allow.
    static func wire(_ item: AttentionItem) -> [String: Any] {
        var out: [String: Any] = [
            "id": item.id.uuidString,
            "kind": item.kind.rawValue,
            "title": item.title,
            "body": item.body,
            "actions": item.actions.map(\.rawValue),
            "priority": item.priority.rawValue,
            "blocking": item.kind.isBlocking,
            "created_at": ISO8601DateFormatter().string(from: item.createdAt),
        ]
        if let expiresAt = item.expiresAt { out["expires_at"] = ISO8601DateFormatter().string(from: expiresAt) }
        if let sessionId = item.sessionId { out["session_id"] = sessionId.uuidString }
        if let taskId = item.taskId { out["task_id"] = taskId.uuidString }
        if let agentId = item.agentId { out["agent_id"] = agentId.uuidString }
        if let toolName = item.toolName { out["tool"] = toolName }
        if item.isPending, let arguments = item.argumentsPreview, !arguments.isEmpty {
            out["arguments_preview"] = String(arguments.prefix(argumentsPreviewLimit))
        }
        if item.isPending, let detail = item.detail,
            let object = try? JSONSerialization.jsonObject(with: detail) as? [String: Any]
        {
            out["detail"] = object
        }
        if let requester = item.requester { out["requester"] = wire(requester) }
        if let agent = item.agent { out["agent"] = wire(agent) }
        switch item.state {
        case .pending: out["state"] = "pending"
        case .retracted: out["state"] = "retracted"
        case .resolved(let resolution):
            out["state"] = "resolved"
            out["outcome"] = resolution.outcome.rawValue
            out["surface"] = resolution.surface.rawValue
            if let by = resolution.decidedBy { out["decided_by"] = wire(by) }
        }
        if !item.isPending {
            // The Insights interaction row for this item carries this id as
            // `attention_id`.
            out["insights_id"] = item.id.uuidString
        }
        if let settledAt = item.settledAt { out["settled_at"] = ISO8601DateFormatter().string(from: settledAt) }
        return out
    }

    /// A participant on the wire: raw fields plus the formatter's label so
    /// every client shows the same text. The reader is the owner's device,
    /// so the owner reads as "You".
    static func wire(_ p: Participant) -> [String: Any] {
        var out: [String: Any] = [
            "kind": p.kind.rawValue,
            "label": ParticipantFormatter.short(p, viewerIsOwner: true),
        ]
        if let handle = p.handle { out["handle"] = handle }
        if let wallet = p.wallet { out["wallet"] = wallet }
        if let name = p.agentName { out["agent_name"] = name }
        if let address = p.agentAddress { out["agent_address"] = address }
        if let owner = p.ownerHandle { out["owner_handle"] = owner }
        if let channel = p.channel { out["channel"] = channel }
        if let user = p.channelUsername { out["channel_username"] = user }
        return out
    }
}

// MARK: - Push

/// What a push carries: no content, only enough for the device to show a
/// generic alert and fetch the item over the Secure Channel.
struct PushPayload: Codable, Equatable, Sendable {
    let itemId: UUID
    let kind: AttentionKind
    /// Generic, content-free alert text ("Approval needed").
    let alert: String
    let blocking: Bool
}

struct PushRegistration: Codable, Equatable, Sendable {
    /// Stable device id from the client.
    let deviceId: String
    /// `apns` / `apns_sandbox` / `fcm`.
    let platform: String
    let token: String
    let registeredAt: Date
}

protocol PushTransport: Sendable {
    var isConfigured: Bool { get }
    func send(_ payload: PushPayload, to registration: PushRegistration) async throws
}

/// The shipped transport: nothing is sent. Logs metadata so the routing can
/// be verified before APNs exists.
struct NoopPushTransport: PushTransport {
    var isConfigured: Bool { false }
    func send(_ payload: PushPayload, to registration: PushRegistration) async throws {
        AttentionLog.info(
            "push (noop) item=\(payload.itemId) kind=\(payload.kind.rawValue) platform=\(registration.platform)"
        )
    }
}

/// Device push tokens, in the Keychain (in memory under tests).
enum PushTokenStore {
    private static let account = "registrations"
    private static let memory = OSAllocatedUnfairLock(initialState: [PushRegistration]())
    private static var inMemory: Bool { KeychainQueryHelpers.usesInMemoryKeychainStoreForTests }

    static func all() -> [PushRegistration] {
        if inMemory || KeychainQueryHelpers.disablesKeychainForProcess { return memory.withLock { $0 } }
        guard let data = Keychain.read(service: OsaurusKeychainServices.pushTokens, account: account) else {
            return []
        }
        return (try? JSONDecoder().decode([PushRegistration].self, from: data)) ?? []
    }

    /// Devices kept; registering past this drops the oldest.
    static let deviceLimit = 10
    /// APNs tokens are 64 hex characters, FCM tokens a few hundred.
    static let tokenLengthLimit = 4_096

    /// Device ids are the phone's own identifier: letters, digits, `-`,
    /// `_`, `.`, up to 128 characters.
    static func isValidDeviceId(_ id: String) -> Bool {
        guard (1 ... 128).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0)
        }
    }

    static func isValidToken(_ token: String) -> Bool {
        (1 ... tokenLengthLimit).contains(token.utf8.count)
            && !token.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }

    static func register(_ registration: PushRegistration) {
        var list = all().filter { $0.deviceId != registration.deviceId }
        list.append(registration)
        if list.count > deviceLimit {
            list = Array(list.sorted { $0.registeredAt < $1.registeredAt }.suffix(deviceLimit))
        }
        write(list)
    }

    static func remove(deviceId: String) {
        write(all().filter { $0.deviceId != deviceId })
    }

    private static func write(_ list: [PushRegistration]) {
        if inMemory || KeychainQueryHelpers.disablesKeychainForProcess {
            memory.withLock { $0 = list }
            return
        }
        guard let data = try? JSONEncoder().encode(list) else { return }
        _ = Keychain.write(service: OsaurusKeychainServices.pushTokens, account: account, data: data)
    }
}

@MainActor
final class PushChannel: NotificationChannel {
    static let shared = PushChannel()

    let id = NotificationChannelID.push
    var transport: any PushTransport = NoopPushTransport()
    var registrations: () -> [PushRegistration] = { PushTokenStore.all() }
    /// Payloads handed to the transport, newest last (bounded; tests and
    /// diagnostics).
    private(set) var sent: [PushPayload] = []

    func shouldDeliver(_ item: AttentionItem) -> Bool { !registrations().isEmpty }

    func deliver(_ item: AttentionItem) {
        let payload = PushPayload(
            itemId: item.id,
            kind: item.kind,
            alert: Self.alert(for: item.kind),
            blocking: item.kind.isBlocking
        )
        sent.append(payload)
        if sent.count > 50 { sent.removeFirst(sent.count - 50) }
        let transport = transport
        for registration in registrations() {
            Task.detached {
                do { try await transport.send(payload, to: registration) } catch {
                    AttentionLog.error("push send failed item=\(payload.itemId): \(error.localizedDescription)")
                }
            }
        }
    }

    func retract(_ item: AttentionItem) {}

    static func alert(for kind: AttentionKind) -> String {
        switch NotificationCategory(kind: kind) {
        case .approvals: return L("Approval needed")
        case .questions: return L("An agent needs your input")
        case .messages: return L("New message")
        case .sharedConversations: return L("Someone is using your shared agent")
        case .agentNotices: return L("Agent notification")
        }
    }
}
