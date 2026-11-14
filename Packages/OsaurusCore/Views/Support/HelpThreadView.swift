//
//  HelpThreadView.swift
//  osaurus
//
//  One report's conversation with the Osaurus team: the messages in order,
//  and a field to write back. Opening it marks the team's replies as read,
//  which clears the Help badge for this report.
//

import SwiftUI

struct HelpThreadView: View {
    let threadId: String

    @ObservedObject private var support = SupportService.shared
    @Environment(\.theme) private var theme

    @State private var reply = ""
    @State private var isSending = false
    @State private var sendError: String?
    @State private var loadError: String?

    /// The full conversation once fetched; until then the list's summary,
    /// so the title and status show at once.
    private var thread: OsaurusRouterSupportThread? {
        support.conversations[threadId] ?? support.threads.first { $0.id == threadId }
    }

    private var messages: [OsaurusRouterSupportMessage]? {
        support.conversations[threadId]?.messages
    }

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: thread?.subject ?? L("Report"),
                verbatimTitle: true,
                subtitle: thread.map(Self.sentLine(for:)),
                verbatimSubtitle: true,
                onRefresh: { Task { await load() } },
                refreshHelp: "Check for replies",
                status: {
                    if let thread {
                        HelpStatusChip(status: thread.status)
                    }
                }
            )
        } content: {
            conversationSection
            if messages != nil {
                replySection
            }
        }
        .task(id: threadId) { await load() }
    }

    // MARK: - Loading

    /// Fetch the conversation, then tell the router it was seen. Reading
    /// happens after the fetch so a reply that failed to load is not marked
    /// as read.
    private func load() async {
        do {
            try await support.loadConversation(id: threadId)
            loadError = nil
            await support.markRead(threadId: threadId)
        } catch {
            loadError = SupportService.userMessage(for: error)
        }
    }

    // MARK: - Conversation

    private var conversationSection: some View {
        SettingsSection(title: "Conversation") {
            if let messages {
                ForEach(messages) { message in
                    HelpMessageRow(message: message)
                }
                if let loadError {
                    // The cached conversation is still shown; say that it
                    // may be behind.
                    SettingsCallout(
                        icon: "exclamationmark.triangle",
                        title: "Could not check for new replies",
                        message: loadError,
                        tone: .warning
                    ) {
                        SettingsButton(.secondary, "Try Again", size: .compact) {
                            Task { await load() }
                        }
                    }
                }
            } else if let loadError {
                SettingsEmptyState(
                    inline: "exclamationmark.triangle",
                    title: "Could not load this report",
                    hint: loadError,
                    action: .init(title: L("Try Again"), icon: "arrow.clockwise") {
                        Task { await load() }
                    }
                )
            } else {
                SettingsEmptyState(loading: "Loading the conversation…")
            }
        }
    }

    // MARK: - Reply

    private var trimmedReply: String {
        reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isTooLong: Bool {
        trimmedReply.count > OsaurusRouterSupportLimits.maxMessageLength
    }

    private var canSend: Bool {
        !trimmedReply.isEmpty && !isTooLong && !isSending
    }

    private var replyHint: String {
        if isTooLong {
            return String(
                format: L("%1$lld characters over the %2$lld character limit."),
                trimmedReply.count - OsaurusRouterSupportLimits.maxMessageLength,
                OsaurusRouterSupportLimits.maxMessageLength
            )
        }
        if thread?.status == .closed {
            return L("This report is closed. Writing again reopens it.")
        }
        return L("Only your message is sent. Please do not paste passwords or keys.")
    }

    private var replySection: some View {
        SettingsSection(title: "Reply") {
            SettingsFieldRow(label: "Your message", hint: replyHint, verbatimHint: true) {
                SettingsTextEditor(
                    text: $reply,
                    placeholder: L("Write a reply"),
                    minHeight: 80,
                    maxHeight: 240,
                    isInvalid: isTooLong
                )
                .disabled(isSending)
            }
            HStack(alignment: .center, spacing: theme.space.s12) {
                Group {
                    if let sendError {
                        Text(verbatim: sendError)
                            .font(SettingsFont.caption)
                            .foregroundColor(theme.status[.error].foreground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SettingsButton(.primary, "Send Reply", icon: "paperplane.fill", isLoading: isSending) {
                    send()
                }
                .disabled(!canSend)
            }
            .settingsRowChrome()
        }
    }

    private func send() {
        guard canSend else { return }
        let text = trimmedReply
        isSending = true
        sendError = nil
        Task {
            do {
                try await support.reply(threadId: threadId, body: text)
                reply = ""
            } catch {
                sendError = SupportService.userMessage(for: error)
            }
            isSending = false
        }
    }

    // MARK: - Copy

    static func sentLine(for thread: OsaurusRouterSupportThread) -> String {
        guard let date = thread.createdDate else { return "" }
        return String(format: L("Sent %@"), date.formatted(date: .abbreviated, time: .shortened))
    }
}

// MARK: - Message Row

/// One message. The team's replies carry the accent so they stand out from
/// the user's own text when scanning a long conversation.
private struct HelpMessageRow: View {
    let message: OsaurusRouterSupportMessage

    @Environment(\.theme) private var theme

    private var author: String {
        message.isFromUser ? L("You") : L("Osaurus team")
    }

    private var timestamp: String {
        message.createdDate?.formatted(date: .abbreviated, time: .shortened) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                Text(verbatim: author)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(message.isFromUser ? theme.text.secondary : theme.text.link)
                Text(verbatim: timestamp)
                    .font(SettingsFont.caption)
                    .foregroundColor(theme.text.tertiary)
                Spacer(minLength: theme.space.s0)
            }
            Text(verbatim: message.body)
                .font(SettingsFont.body)
                .foregroundColor(theme.text.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .settingsRowChrome()
        .accessibilityElement(children: .combine)
    }
}
