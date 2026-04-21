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

// MARK: - Pinned Facts Panel

struct PinnedFactsPanel: View {
    @Environment(\.theme) private var theme

    let facts: [PinnedFact]
    let onDelete: (String) -> Void

    @State private var searchText = ""

    private var filteredFacts: [PinnedFact] {
        guard !searchText.isEmpty else { return facts }
        return facts.filter { $0.content.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                TextField(text: $searchText, prompt: Text("Search pinned facts...", bundle: .module)) {
                    Text("Search pinned facts...", bundle: .module)
                }
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )

            HStack {
                Text("\(filteredFacts.count) of \(facts.count) facts", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                Spacer()
            }

            if filteredFacts.isEmpty {
                HStack {
                    Spacer()
                    Text("No matching facts", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                    Spacer()
                }
                .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredFacts) { fact in
                            PinnedFactRow(
                                fact: fact,
                                onDelete: { onDelete(fact.id) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Pinned Fact Row

struct PinnedFactRow: View {
    @Environment(\.theme) private var theme

    let fact: PinnedFact
    let onDelete: () -> Void

    @State private var isHovering = false

    private var salienceColor: Color {
        if fact.salience >= 0.7 { return .green }
        if fact.salience >= 0.4 { return .blue }
        return .orange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // Salience bar
                HStack(spacing: 2) {
                    ForEach(0 ..< 5, id: \.self) { idx in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(
                                Double(idx) / 5.0 < fact.salience
                                    ? salienceColor : theme.tertiaryBackground
                            )
                            .frame(width: 4, height: 8)
                    }
                }

                Text(String(format: "%.0f%%", fact.salience * 100))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)

                if fact.useCount > 0 {
                    Text("· used \(fact.useCount)×", bundle: .module)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                }

                Spacer()

                if isHovering {
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundColor(theme.errorColor.opacity(0.7))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .transition(.opacity)
                }
            }

            Text(fact.content)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .lineLimit(3)

            HStack(spacing: 6) {
                if !fact.tags.isEmpty {
                    ForEach(fact.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10))
                            .foregroundColor(theme.tertiaryText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(theme.tertiaryBackground)
                            )
                    }
                }
                Spacer()
                Text(fact.createdAt)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? theme.inputBackground : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Pinned fact: \(fact.content). Salience \(Int(fact.salience * 100)) percent"
        )
        .accessibilityHint("Hover to reveal delete option")
    }
}

// MARK: - Episode Row

struct EpisodeRow: View {
    @Environment(\.theme) private var theme

    let episode: Episode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(episode.tokenCount) tokens", bundle: .module)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)

                Text("· salience \(String(format: "%.0f%%", episode.salience * 100))", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)

                Spacer()

                Text(episode.conversationAt)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            Text(episode.summary)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)

            if !episode.topicsCSV.isEmpty {
                Text("topics: \(episode.topicsCSV)")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Episode: \(episode.summary). \(episode.tokenCount) tokens, \(episode.conversationAt)"
        )
    }
}

// MARK: - Section Card

struct MemorySectionCard<Trailing: View, Content: View>: View {
    @Environment(\.theme) private var theme

    let title: String
    let icon: String
    var count: Int? = nil
    let trailing: Trailing
    let content: Content

    init(
        title: String,
        icon: String,
        count: Int? = nil,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.count = count
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 20)

                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.primaryText)
                    .tracking(0.5)

                if let count {
                    Text("\(count)", bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.tertiaryBackground))
                }

                Spacer()

                trailing
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

extension MemorySectionCard where Trailing == EmptyView {
    init(
        title: String,
        icon: String,
        count: Int? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.count = count
        self.trailing = EmptyView()
        self.content = content()
    }
}

// MARK: - Section Action Button

struct MemorySectionActionButton: View {
    @Environment(\.theme) private var theme

    let title: String
    let icon: String?
    let action: () -> Void

    @State private var isHovering = false

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(isHovering ? theme.accentColor : theme.secondaryText)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? theme.accentColor.opacity(0.1) : Color.clear)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Override Row

struct MemoryOverrideRow: View {
    @Environment(\.theme) private var theme

    let content: String
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(theme.accentColor)
                .frame(width: 6, height: 6)

            Text(content)
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
                .lineLimit(2)

            Spacer()

            if isHovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
                .transition(.opacity)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Agent Memory Row

struct MemoryAgentRow: View {
    @Environment(\.theme) private var theme

    let agent: Agent
    let count: Int
    let onSelect: () -> Void
    let onPreviewContext: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    Circle()
                        .fill(agentColorFor(agent.name))
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(theme.primaryText)

                        if !agent.description.isEmpty {
                            Text(agent.description)
                                .font(.system(size: 11))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Text(pluralizedMemory(count, "memory", "memories"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.tertiaryBackground))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: onPreviewContext) {
                Image(systemName: "eye")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.tertiaryBackground)
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .help(Text("Preview context for this agent", bundle: .module))

            Button(action: onSelect) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? theme.accentColor.opacity(0.06) : Color.clear)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Identity Edit Sheet

struct IdentityEditSheet: View {
    let identity: Identity?
    let onSave: (String) -> Void

    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @Environment(\.dismiss) private var dismiss
    @State private var editText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Identity", bundle: .module)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Manually edit the auto-derived identity narrative", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(20)

            Divider().opacity(0.5)

            TextEditor(text: $editText)
                .font(.system(size: 13))
                .padding(12)
                .scrollContentBackground(.hidden)
                .background(theme.inputBackground)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            Divider().opacity(0.5)

            HStack {
                Text(pluralizedMemory(max(1, editText.count / MemoryConfiguration.charsPerToken), "token"))
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)

                Spacer()

                Button(action: { dismiss() }) {
                    Text("Cancel", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.tertiaryBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(PlainButtonStyle())

                Button {
                    onSave(editText)
                    dismiss()
                } label: {
                    Text("Save", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            }
            .padding(20)
        }
        .background(theme.primaryBackground)
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
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Override", bundle: .module)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("Enter an explicit fact that should always be in your identity", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(20)

            Divider().opacity(0.5)

            TextField(text: $text, prompt: Text("e.g., My name is Terence", bundle: .module)) {
                Text("e.g., My name is Terence", bundle: .module)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($isFocused)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                isFocused ? theme.accentColor.opacity(0.5) : theme.inputBorder,
                                lineWidth: isFocused ? 1.5 : 1
                            )
                    )
            )
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().opacity(0.5)

            HStack {
                Spacer()

                Button(action: { dismiss() }) {
                    Text("Cancel", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.tertiaryBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(theme.inputBorder, lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(PlainButtonStyle())

                Button {
                    guard !trimmedText.isEmpty else { return }
                    onAdd(trimmedText)
                    dismiss()
                } label: {
                    Text("Add", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(theme.accentColor))
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(trimmedText.isEmpty)
                .opacity(trimmedText.isEmpty ? 0.5 : 1)
            }
            .padding(20)
        }
        .background(theme.primaryBackground)
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
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Memory Context Preview", bundle: .module)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("This is injected before the system prompt on each message", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                }
                Spacer()

                Text(
                    "~\(pluralizedMemory(max(1, context.count / MemoryConfiguration.charsPerToken), "token"))",
                    bundle: .module
                )
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.tertiaryBackground))

                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(theme.tertiaryBackground)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(20)

            Divider().opacity(0.5)

            ScrollView {
                Text(context)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
    }
}
