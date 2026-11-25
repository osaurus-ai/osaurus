//
//  MemoryComponents.swift
//  osaurus
//
//  v2 memory UI components shared between MemoryView and AgentDetailView:
//  pinned-facts panel, episode row, override row, agent row, the section
//  card chrome, and the three sheets (identity edit, add override,
//  context preview).
//

import SwiftUI

func pluralizedMemory(_ count: Int, _ singular: String, _ plural: String? = nil) -> String {
    count == 1 ? "1 \(singular)" : "\(count) \(plural ?? "\(singular)s")"
}

// MARK: - Pinned Facts Section

/// The agent page's Pinned Facts group: search in the header, one row per
/// fact, and a Show All row past the preview limit.
struct PinnedFactsSection: View {
    @Environment(\.theme) private var inheritedTheme
    private var theme: any ThemeProtocol { inheritedTheme }

    let facts: [PinnedFact]
    let onDelete: (String) -> Void

    private static let previewLimit = 10
    private static let searchThreshold = 5

    @State private var searchText = ""
    @State private var showsAll = false

    /// Debounced filter result. Previously a body computed property,
    /// which meant `localizedCaseInsensitiveContains` ran across every
    /// fact for every keystroke (and for every parent-publish that
    /// caused this view's body to re-evaluate). The `.task(id:)`
    /// modifier below recomputes only after a 150 ms idle window.
    @State private var filteredFacts: [PinnedFact] = []

    private var caption: String? {
        guard !facts.isEmpty else { return nil }
        guard !searchText.isEmpty else { return "\(facts.count)" }
        return facts.count == 1
            ? L("\(filteredFacts.count) of 1 fact")
            : L("\(filteredFacts.count) of \(facts.count) facts")
    }

    private var displayedFacts: [PinnedFact] {
        showsAll ? filteredFacts : Array(filteredFacts.prefix(Self.previewLimit))
    }

    var body: some View {
        SettingsSection(
            title: "Pinned Facts",
            caption: caption,
            subtitle: "Facts promoted from your chats once they come up often enough. The agent always keeps these in mind."
        ) {
            if facts.count > Self.searchThreshold {
                SearchField(text: $searchText, placeholder: "Search pinned facts...")
            }
        } content: {
            if facts.isEmpty {
                SettingsEmptyState(inline: "pin.slash", title: "No pinned facts yet")
            } else if filteredFacts.isEmpty {
                SettingsEmptyState(inline: "magnifyingglass", title: "No matching facts")
            } else {
                ForEach(displayedFacts) { fact in
                    PinnedFactRow(fact: fact, onDelete: { onDelete(fact.id) })
                }
                if filteredFacts.count > Self.previewLimit {
                    HStack {
                        SettingsButton(
                            .tertiary,
                            showsAll ? L("Show Less") : L("Show All \(filteredFacts.count)"),
                            size: .compact,
                            verbatim: true
                        ) {
                            withAnimation(theme.motion.quick) { showsAll.toggle() }
                        }
                        Spacer()
                    }
                }
            }
        }
        .onAppear { recomputeFilter() }
        .onChange(of: facts.count) { _, _ in recomputeFilter() }
        .task(id: searchText) {
            // 150 ms debounce keeps the list responsive without
            // re-running the localized contains over the whole pinned-
            // facts collection on every keystroke. We still rerun
            // immediately on `facts` mutations (above) so an add/
            // delete reflects without a debounce delay.
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled {
                recomputeFilter()
            }
        }
    }

    private func recomputeFilter() {
        let query = searchText
        if query.isEmpty {
            filteredFacts = facts
            return
        }
        filteredFacts = facts.filter { $0.content.localizedCaseInsensitiveContains(query) }
    }
}

// MARK: - Pinned Fact Row

/// A grouped row: the fact as the title, salience, use count, tags and date
/// beneath, and a delete button revealed on hover.
struct PinnedFactRow: View {
    @Environment(\.theme) private var inheritedTheme
    private var theme: any ThemeProtocol { inheritedTheme }

    let fact: PinnedFact
    let onDelete: () -> Void

    @State private var isHovering = false

    private var salienceColor: Color {
        if fact.salience >= 0.7 { return theme.status.success.foreground }
        if fact.salience >= 0.4 { return theme.status.info.foreground }
        return theme.status.warning.foreground
    }

    var body: some View {
        HStack(alignment: .center, spacing: theme.space.s12) {
            SettingsRowText {
                Text(fact.content)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            } description: {
                HStack(spacing: theme.space.s6) {
                    // Salience bar
                    HStack(spacing: theme.space.s2) {
                        ForEach(0 ..< 5, id: \.self) { idx in
                            RoundedRectangle(cornerRadius: theme.radius.small)
                                .fill(
                                    Double(idx) / 5.0 < fact.salience
                                        ? salienceColor : theme.surface.hover
                                )
                                .frame(width: 4, height: 8)
                        }
                    }
                    Text(String(format: "%.0f%%", fact.salience * 100))
                    if fact.useCount > 0 {
                        Text("· used \(fact.useCount)×", bundle: .module)
                    }
                    Text(verbatim: "· \(fact.createdAt)")
                        .lineLimit(1)
                    ForEach(fact.tags.prefix(3), id: \.self) { tag in
                        StatusChip(tag, tone: .neutral)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsIconButton("trash", help: "Delete", size: .compact, isDestructive: true, action: onDelete)
                .opacity(isHovering ? 1 : 0)
                .accessibilityHidden(!isHovering)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(theme.motion.quick) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Pinned fact: \(fact.content). Salience \(Int(fact.salience * 100)) percent"
        )
        .accessibilityAction(named: Text("Delete", bundle: .module), onDelete)
    }
}

// MARK: - Episode Row

/// A grouped row: the summary as the title, date, size, salience and topics
/// beneath.
struct EpisodeRow: View {
    @Environment(\.theme) private var inheritedTheme
    private var theme: any ThemeProtocol { inheritedTheme }

    let episode: Episode

    var body: some View {
        let tokenLabel =
            episode.tokenCount == 1 ? L("1 token") : L("\(episode.tokenCount) tokens")
        SettingsRowText {
            Text(episode.summary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        } description: {
            HStack(spacing: theme.space.s6) {
                Text(verbatim: episode.conversationAt)
                Text(verbatim: "· \(tokenLabel)")
                Text("· salience \(String(format: "%.0f%%", episode.salience * 100))", bundle: .module)
                if !episode.topicsCSV.isEmpty {
                    Text(verbatim: "· \(episode.topicsCSV)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Episode: \(episode.summary). \(tokenLabel), \(episode.conversationAt)"
        )
    }
}

// MARK: - Override Row

struct MemoryOverrideRow: View {
    let content: String
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        SettingsRow(title: content, description: "", verbatimTitle: true) {
            SettingsIconButton("xmark", help: "Remove override", size: .compact, isDestructive: true, action: onDelete)
                .opacity(isHovering ? 1 : 0)
                .accessibilityHidden(!isHovering)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}

/// "12 memories" beside a memory row's actions.
struct MemoryCountLabel: View {
    @Environment(\.theme) private var inheritedTheme
    private var theme: any ThemeProtocol { inheritedTheme }
    let count: Int

    var body: some View {
        Text(pluralizedMemory(count, "memory", "memories"))
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .lineLimit(1)
    }
}

// MARK: - Agent Memory Row

struct MemoryAgentRow: View {
    @Environment(\.theme) private var theme
    let agent: Agent
    let count: Int
    let onSelect: () -> Void
    let onPreviewContext: () -> Void

    var body: some View {
        LibraryRow(
            title: agent.name,
            subtitle: agent.displayDescription,
            showsChevron: true,
            action: onSelect
        ) {
            Circle()
                .fill(theme.dataInk(seed: agent.name))
                .frame(width: 8, height: 8)
        } trailing: {
            MemoryCountLabel(count: count)
            SettingsIconButton("eye", help: "Preview context for this agent", size: .compact, action: onPreviewContext)
        }
    }
}

// MARK: - Identity Edit Sheet

struct IdentityEditSheet: View {
    let identity: Identity?
    let onSave: (String) -> Void

    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: any ThemeProtocol { themeManager.currentTheme }

    @Environment(\.dismiss) private var dismiss
    @State private var editText: String = ""

    var body: some View {
        VStack(spacing: theme.space.s0) {
            HStack {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text("Edit Identity", bundle: .module)
                        .catalogTypography(.heading, theme: theme, fallback: SettingsFont.detailTitle)
                        .foregroundColor(theme.text.primary)
                    Text("Manually edit the auto-derived identity narrative", bundle: .module)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .glyphSize(.caption, weight: .semibold)
                        .foregroundColor(theme.text.secondary)
                        .frame(width: 28, height: 28)
                        .settingsChrome(.inset)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)

            ThemeHairlineDivider()

            SettingsTextEditor(text: $editText)

            ThemeHairlineDivider()

            HStack {
                Text(pluralizedMemory(max(1, editText.count / MemoryConfiguration.charsPerToken), "token"))
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)

                Spacer()

                Button(action: { dismiss() }) {
                    Text("Cancel", bundle: .module)
                }
                .assignedSettingsButtonStyle(.secondary)
                .keyboardShortcut(.cancelAction)

                Button {
                    onSave(editText)
                    dismiss()
                } label: {
                    Text("Save", bundle: .module)
                }
                .assignedSettingsButtonStyle(.primary)
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
        }
        .background(theme.surface.canvas)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            editText = identity?.content ?? ""
        }
    }
}

// MARK: - Add Override Sheet

struct AddOverrideSheet: View {
    let onAdd: (String) -> Void

    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: any ThemeProtocol { themeManager.currentTheme }

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: theme.space.s0) {
            HStack {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text("Add Override", bundle: .module)
                        .catalogTypography(.heading, theme: theme, fallback: SettingsFont.detailTitle)
                        .foregroundColor(theme.text.primary)
                    Text("Enter an explicit fact that should always be in your identity", bundle: .module)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .glyphSize(.caption, weight: .semibold)
                        .foregroundColor(theme.text.secondary)
                        .frame(width: 28, height: 28)
                        .settingsChrome(.inset)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)

            ThemeHairlineDivider()

            SettingsTextField(placeholder: L("e.g., My name is Terence"), text: $text, focus: $isFocused)
            .padding(.horizontal, theme.space.s16)
            .padding(.vertical, theme.space.s16)

            ThemeHairlineDivider()

            HStack {
                Spacer()

                Button(action: { dismiss() }) {
                    Text("Cancel", bundle: .module)
                }
                .assignedSettingsButtonStyle(.secondary)
                .keyboardShortcut(.cancelAction)

                Button {
                    guard !trimmedText.isEmpty else { return }
                    onAdd(trimmedText)
                    dismiss()
                } label: {
                    Text("Add", bundle: .module)
                }
                .assignedSettingsButtonStyle(.primary)
                .disabled(trimmedText.isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
        }
        .background(theme.surface.canvas)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear { isFocused = true }
    }
}

// MARK: - Context Preview Sheet

struct ContextPreviewItem: Identifiable {
    let id = UUID()
    let text: String
}

struct ContextPreviewSheet: View {
    let context: String

    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: any ThemeProtocol { themeManager.currentTheme }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: theme.space.s0) {
            HStack {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text("Memory Context Preview", bundle: .module)
                        .catalogTypography(.heading, theme: theme, fallback: SettingsFont.detailTitle)
                        .foregroundColor(theme.text.primary)
                    Text("This is injected before the system prompt on each message", bundle: .module)
                        .catalogTypography(.body, theme: theme, fallback: SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                }
                Spacer()

                StatusChip(L("~\(pluralizedMemory(max(1, context.count / MemoryConfiguration.charsPerToken), "token"))"))

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .glyphSize(.caption, weight: .semibold)
                        .foregroundColor(theme.text.secondary)
                        .frame(width: 28, height: 28)
                        .settingsChrome(.inset)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)

            ThemeHairlineDivider()

            ScrollView {
                Text(context)
                    .componentInspectionText(53, role: .code, fallback: .footnote, family: .code, theme: theme)
                    .foregroundColor(theme.text.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
            }
        }
        .background(theme.surface.canvas)
        .environment(\.theme, themeManager.currentTheme)
    }
}

// MARK: - Project Memory Row

/// Row for a shared project-memory namespace in the Memory view's Agents
/// tab. `name` nil means the project record is gone (orphaned namespace) —
/// the row says so and Forget doubles as cleanup.
struct MemoryProjectRow: View {
    @Environment(\.theme) private var inheritedTheme
    private var theme: any ThemeProtocol { inheritedTheme }

    let name: String?
    let count: Int
    let onPreviewContext: () -> Void
    let onForget: () -> Void

    var body: some View {
        LibraryRow(
            title: name ?? L("Deleted project"),
            subtitle: L("Shared by every chat in this project")
        ) {
            SettingsIconTile(icon: "folder", tint: name == nil ? theme.text.tertiary : theme.text.secondary)
        } trailing: {
            MemoryCountLabel(count: count)
            SettingsIconButton(
                "eye", help: "Preview context for this project", size: .compact, action: onPreviewContext)
            SettingsIconButton(
                "trash", help: "Forget this project's shared memory", size: .compact, isDestructive: true,
                action: onForget)
        }
    }
}
