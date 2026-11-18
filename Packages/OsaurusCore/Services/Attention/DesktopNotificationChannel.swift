//
//  DesktopNotificationChannel.swift
//  osaurus
//
//  macOS notifications for attention items, with actions that answer the
//  item in place: Approve / Allow for This Conversation / Deny for
//  approvals, a text Reply for questions and messages. The notification
//  center and its delegate stay in `NotificationService`; this channel owns
//  the content, categories and the mapping from an action back to
//  `AttentionCenter.resolve`.
//

import AppKit
import Foundation
import UserNotifications

@MainActor
final class DesktopNotificationChannel: NotificationChannel {
    static let shared = DesktopNotificationChannel()

    let id = NotificationChannelID.desktop

    nonisolated static let userInfoKey = "attentionId"

    enum Category: String, CaseIterable {
        /// Allow / Deny, the Inbox row's answers.
        case approval = "OSU_ATTENTION_APPROVAL"
        /// Allow / Allow for This Conversation / Deny: any request that
        /// offers a conversation grant, a teammate's or this Mac's.
        case approvalForConversation = "OSU_ATTENTION_OWNER_APPROVAL"
        case reply = "OSU_ATTENTION_REPLY"
        case open = "OSU_ATTENTION_OPEN"
    }

    enum Action: String {
        case approve = "OSU_ATTENTION_APPROVE"
        case allowForConversation = "OSU_ATTENTION_ALLOW_CONVERSATION"
        case deny = "OSU_ATTENTION_DENY"
        case reply = "OSU_ATTENTION_REPLY_TEXT"
    }

    /// Posts and removals; replaced in tests.
    var poster: (UNNotificationRequest) -> Void = { request in
        let attentionId = (request.content.userInfo[DesktopNotificationChannel.userInfoKey] as? String)
            .flatMap(UUID.init(uuidString:))
        NotificationService.shared.add(request) {
            guard let attentionId else { return true }
            return AttentionCenter.shared.pending.contains { $0.id == attentionId }
        }
    }
    var remover: ([String]) -> Void = { NotificationService.shared.removeDelivered(identifiers: $0) }
    /// Whether the app is frontmost; replaced in tests.
    var appIsActive: () -> Bool = { NSApp?.isActive ?? false }

    func shouldDeliver(_ item: AttentionItem) -> Bool {
        let prefs = NotificationPreferencesStore.snapshot()
        if prefs.desktopOnlyWhenInactive, appIsActive(), item.hasInlineCard { return false }
        if let sessionId = item.sessionId, ChatWindowManager.shared.isSessionFrontmost(sessionId) { return false }
        return true
    }

    func deliver(_ item: AttentionItem) {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.body = item.body
        content.userInfo = [Self.userInfoKey: item.id.uuidString]
        content.categoryIdentifier = Self.category(for: item).rawValue
        content.threadIdentifier = item.sessionId?.uuidString ?? item.kind.rawValue
        if item.kind.isBlocking { content.interruptionLevel = .timeSensitive }
        poster(UNNotificationRequest(identifier: Self.identifier(item.id), content: content, trigger: nil))
    }

    func retract(_ item: AttentionItem) {
        remover([Self.identifier(item.id)])
    }

    static func identifier(_ id: UUID) -> String { "attention-\(id.uuidString)" }

    static func category(for item: AttentionItem) -> Category {
        if item.actions.contains(.allowForConversation) { return .approvalForConversation }
        if item.actions.contains(.approve) { return .approval }
        if item.actions.contains(.reply) { return .reply }
        return .open
    }

    /// Registered by `NotificationService.configureOnLaunch` beside its own.
    static func categories() -> [UNNotificationCategory] {
        let approve = UNNotificationAction(identifier: Action.approve.rawValue, title: L("Allow"), options: [])
        let allowConversation = UNNotificationAction(
            identifier: Action.allowForConversation.rawValue,
            title: L("Allow for This Conversation"),
            options: []
        )
        let deny = UNNotificationAction(identifier: Action.deny.rawValue, title: L("Deny"), options: [.destructive])
        let reply = UNTextInputNotificationAction(
            identifier: Action.reply.rawValue,
            title: L("Reply"),
            options: [],
            textInputButtonTitle: L("Send"),
            textInputPlaceholder: L("Your answer")
        )
        return [
            UNNotificationCategory(
                identifier: Category.approval.rawValue, actions: [approve, deny], intentIdentifiers: [],
                options: [.customDismissAction]),
            UNNotificationCategory(
                identifier: Category.approvalForConversation.rawValue, actions: [approve, allowConversation, deny],
                intentIdentifiers: [], options: [.customDismissAction]),
            UNNotificationCategory(
                identifier: Category.reply.rawValue, actions: [reply], intentIdentifiers: [],
                options: [.customDismissAction]),
            UNNotificationCategory(
                identifier: Category.open.rawValue, actions: [], intentIdentifiers: [],
                options: [.customDismissAction]),
        ]
    }

    static let dismissActionIdentifier = UNNotificationDismissActionIdentifier

    /// Handles a response for an attention notification. Returns false when
    /// the notification isn't one.
    nonisolated static func handle(actionIdentifier: String, userInfo: [AnyHashable: Any], replyText: String?) -> Bool {
        guard let raw = userInfo[userInfoKey] as? String, let id = UUID(uuidString: raw) else { return false }
        Task { @MainActor in
            let center = AttentionCenter.shared
            if actionIdentifier == dismissActionIdentifier {
                // Swiping a notice away dismisses it everywhere; a blocking
                // item stays answerable from the app and the phone.
                if let item = center.item(id: id), item.state == .pending, !item.kind.isBlocking {
                    center.retract(id: id)
                }
                return
            }
            guard let item = center.item(id: id) else {
                // The run that asked is gone (Osaurus quit or the item aged out).
                shared.postEnded()
                return
            }
            let owner = Participant.owner()
            let resolution: AttentionResolution
            switch Action(rawValue: actionIdentifier) {
            case .approve:
                resolution = AttentionResolution(outcome: .approved, surface: .desktop, decidedBy: owner)
            case .allowForConversation:
                resolution = AttentionResolution(outcome: .allowedForConversation, surface: .desktop, decidedBy: owner)
            case .deny:
                resolution = AttentionResolution(outcome: .denied, surface: .desktop, decidedBy: owner)
            case .reply:
                let text = replyText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else { return }
                resolution = AttentionResolution(
                    outcome: .replied, surface: .desktop, decidedBy: owner,
                    replyText: String(text.prefix(AttentionLimits.textCharacters)))
            case nil:
                // Default click: open where the item lives. Non-blocking
                // items are dismissed by opening them.
                AttentionOpener.open(item)
                if item.state == .pending, !item.kind.isBlocking { center.retract(id: id) }
                return
            }
            center.resolve(id: id, with: resolution)
        }
        return true
    }

    /// Tells the owner an action landed on a request that no longer exists.
    func postEnded() {
        let content = UNMutableNotificationContent()
        content.title = L("This request has ended")
        content.body = L("It ended when Osaurus quit or the run stopped. Nothing was approved.")
        poster(UNNotificationRequest(identifier: "attention-ended-\(UUID().uuidString)", content: content, trigger: nil))
    }
}
