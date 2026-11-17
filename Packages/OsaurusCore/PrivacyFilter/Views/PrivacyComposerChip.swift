//
//  PrivacyComposerChip.swift
//  osaurus / PrivacyFilter
//
//  Composer chip that shows how Privacy Filter treats this conversation
//  (Review / Auto / Off) and how many values it has redacted so far.
//  Its menu switches the conversation policy, lists the redactions (each
//  can stop being redacted), forgets them, and opens Settings. Shown only
//  when the filter applies to the selected cloud provider.
//

import SwiftUI

/// What the composer's privacy chip needs from the chat. Passed through
/// the environment because the composer's initializer call site in
/// `ChatView` is already at the type-checker's limit.
struct PrivacyComposerContext {
    /// The conversation's privacy scope, `nil` before its first send.
    var scopeId: String?
    /// Remote provider of the selected model; `nil` for local models.
    var providerId: UUID?
    /// Mint the conversation id so a policy can be set before the first send.
    var ensureScopeId: @MainActor () -> String?
    /// Clear this conversation's redactions (map and chat highlights).
    var forget: @MainActor () -> Void
}

private struct PrivacyComposerContextKey: EnvironmentKey {
    static let defaultValue: PrivacyComposerContext? = nil
}

extension EnvironmentValues {
    var privacyComposerContext: PrivacyComposerContext? {
        get { self[PrivacyComposerContextKey.self] }
        set { self[PrivacyComposerContextKey.self] = newValue }
    }
}

struct PrivacyComposerChip: View {
    @Environment(\.theme) private var theme
    @Environment(\.privacyComposerContext) private var context

    @State private var configuration = PrivacyFilterStore.snapshot()
    @State private var policy: ConversationPrivacyPolicy = .ask
    @State private var isExplicit = false
    @State private var redactionCount = 0
    @State private var hasCategoryAnswers = false
    @State private var showsRedactions = false

    private var isVisible: Bool {
        guard let context, let providerId = context.providerId else { return false }
        return configuration.isEnabled(forProviderId: providerId)
    }

    private var defaultPolicy: ConversationPrivacyPolicy {
        ConversationPrivacyPolicy(configuration.defaultReviewPolicy)
    }

    var body: some View {
        Group {
            if isVisible {
                visibleChip
            } else {
                Color.clear.frame(maxWidth: 0, maxHeight: 0)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .privacyFilterConfigurationChanged)) { _ in
            configuration = PrivacyFilterStore.snapshot()
            Task { await refresh() }
        }
    }

    private var visibleChip: some View {
        chip
            .task(id: context?.scopeId) { await refresh() }
            .onReceive(NotificationCenter.default.publisher(for: .privacyConversationPolicyChanged)) { note in
                let scope = note.userInfo?["scopeId"] as? String
                if scope == nil || scope == "" || scope == context?.scopeId {
                    Task { await refresh() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .privacyFilterRedactionsApproved)) { note in
                if note.userInfo?["sessionId"] as? String == context?.scopeId {
                    Task { await refresh() }
                }
            }
    }

    private var chip: some View {
        SettingsActionMenu(accessibilityLabel: helpText) {
            Section {
                ForEach(ConversationPrivacyPolicy.allCases, id: \.self) { option in
                    Toggle(
                        isOn: Binding(
                            get: { policy == option },
                            set: { if $0 { setPolicy(option) } }
                        )
                    ) {
                        Text(verbatim: option.menuTitle)
                    }
                    .settingsCheckbox()
                }
            } header: {
                Text(localized: "This Conversation")
            }

            if isExplicit, policy != defaultPolicy {
                Button(L("Use Default (\(defaultPolicy.menuTitle))")) { setPolicy(nil) }
            }

            Divider()

            Button(L("Redactions in This Conversation (\(redactionCount))…")) {
                showsRedactions = true
            }
            .disabled(redactionCount == 0)

            Button(localized: "Forget Redactions in This Conversation") {
                context?.forget()
            }
            .disabled(redactionCount == 0 && !hasCategoryAnswers)

            Divider()

            Button(localized: "Privacy Filter Settings…") {
                ManagementStateManager.shared.privacySubTabRequest = PrivacyTab.overview.rawValue
                AppDelegate.shared?.showManagementWindow(initialTab: .privacy)
            }
        } label: {
            SharedChipContent(spacing: theme.space.s4) {
                Image(systemName: policy.chipIcon)
                    .composerChipTextStyle(.caption, property: "caption")
                    .composerChipInk(policy == .off ? "error" : "secondary", fallback: policy == .off ? theme.status.warning.foreground : theme.text.secondary)
                Text(verbatim: policy.chipTitle)
                    .composerChipTextStyle(.caption, weight: 500)
                    .composerChipInk("foreground", fallback: theme.text.secondary)
                    .lineLimit(1)
                if redactionCount > 0 {
                    Text(verbatim: "· \(redactionCount)")
                        .composerChipTextStyle(.caption, monospacedDigit: true, property: "caption")
                        .composerChipInk("secondary", fallback: theme.text.tertiary)
                }
            }
            .composerChipSurface()
        }
        .composerChipButtonStyle()
        .fixedSize()
        .help(Text(verbatim: helpText))
        .popover(isPresented: $showsRedactions, arrowEdge: .top) {
            if let scopeId = context?.scopeId {
                ConversationRedactionsPopover(scopeId: scopeId) {
                    Task { await refresh() }
                }
                .environment(\.theme, theme)
            }
        }
    }

    private var helpText: String {
        let state = L("Privacy Filter: \(policy.menuTitle)")
        guard redactionCount > 0 else { return state }
        return state + " · " + L("\(redactionCount) redacted in this conversation")
    }

    private func setPolicy(_ newPolicy: ConversationPrivacyPolicy?) {
        guard let scopeId = context?.scopeId ?? context?.ensureScopeId() else { return }
        policy = newPolicy ?? defaultPolicy
        isExplicit = newPolicy != nil
        Task { await SessionRedactionStore.shared.setPolicy(scopeId, newPolicy) }
    }

    private func refresh() async {
        configuration = PrivacyFilterStore.snapshot()
        guard let scopeId = context?.scopeId else {
            policy = defaultPolicy
            isExplicit = false
            redactionCount = 0
            hasCategoryAnswers = false
            return
        }
        let store = SessionRedactionStore.shared
        let explicit = await store.explicitPolicy(scopeId)
        let decisions = await store.categoryDecisions(scopeId)
        let count = await store.get(scopeId)?.snapshot().count ?? 0
        policy = explicit ?? defaultPolicy
        isExplicit = explicit != nil
        hasCategoryAnswers = !decisions.isEmpty
        redactionCount = count
    }
}

/// Every value redacted in this conversation, with a way to stop
/// redacting each one from the next message on.
private struct ConversationRedactionsPopover: View {
    @Environment(\.theme) private var theme
    let scopeId: String
    let onChange: () -> Void

    private struct Row: Identifiable {
        let placeholder: Placeholder
        let original: String
        var id: Placeholder { placeholder }
    }

    @State private var rows: [Row] = []
    /// A popover sizes to its content's ideal height, and a ScrollView has
    /// none, so the list gets the height its rows measure, up to a cap.
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            Text(localized: "Redactions in This Conversation")
                .catalogTypography(.heading, theme: theme, fallback: SettingsFont.sectionTitle)
                .foregroundColor(theme.text.primary)
            Text(localized: "Stopped values are sent as written from your next message on.")
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: theme.space.s6) {
                    ForEach(rows) { row in
                        HStack(spacing: theme.space.s8) {
                            Image(systemName: row.placeholder.category.reviewIcon)
                                .glyphSize(.footnote, weight: .medium)
                                .foregroundColor(theme.text.link)
                            Text(verbatim: row.original)
                                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                                .foregroundColor(theme.text.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: theme.space.s8)
                            StatusChip(row.placeholder.token, tone: .accent)
                            SettingsButton(.secondary, "Stop redacting", size: .compact) {
                                stopRedacting(row.original)
                            }
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { height in
                    if abs(listHeight - height) > 0.5 { listHeight = height }
                }
            }
            .frame(height: min(listHeight, 280))
        }
        .padding(theme.space.s16)
        .frame(minWidth: 380, idealWidth: 440)
        .background(theme.surface.canvas)
        .task { await load() }
    }

    private func load() async {
        let snapshot = await SessionRedactionStore.shared.get(scopeId)?.snapshot() ?? []
        rows = snapshot
            .map { Row(placeholder: $0.0, original: $0.1) }
            .sorted { $0.placeholder.token < $1.placeholder.token }
    }

    private func stopRedacting(_ original: String) {
        Task {
            await SessionRedactionStore.shared.get(scopeId)?.stopRedacting([original])
            await load()
            onChange()
        }
    }
}
