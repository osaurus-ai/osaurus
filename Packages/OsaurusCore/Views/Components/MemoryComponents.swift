//
//  MemoryComponents.swift
//  osaurus
//
//  Memory UI components used by AgentDetailView for working memory and summaries.
//

import SwiftUI

// MARK: - Agent Entries Panel

struct AgentEntriesPanel: View {
    @Environment(\.theme) private var theme

    let entries: [MemoryEntry]
    let onDelete: (String) -> Void

    @State private var searchText = ""
    @State private var filterType: MemoryEntryType?

    private var filteredEntries: [MemoryEntry] {
        entries.filter { entry in
            if let filterType, entry.type != filterType { return false }
            if !searchText.isEmpty {
                return entry.content.localizedCaseInsensitiveContains(searchText)
            }
            return true
        }
    }

    private var activeTypes: [MemoryEntryType] {
        let types = Set(entries.map(\.type))
        return MemoryEntryType.allCases.filter { types.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                    TextField("Search entries...", text: $searchText)
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

                if activeTypes.count > 1 {
                    HStack(spacing: 4) {
                        MemoryFilterChip(label: "All", isSelected: filterType == nil) {
                            filterType = nil
                        }
                        ForEach(activeTypes, id: \.self) { type in
                            MemoryFilterChip(label: type.displayName, isSelected: filterType == type) {
                                filterType = filterType == type ? nil : type
                            }
                        }
                    }
                }
            }

            HStack {
                Text("\(filteredEntries.count) of \(entries.count) entries")
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                Spacer()
            }

            if filteredEntries.isEmpty {
                HStack {
                    Spacer()
                    Text("No matching entries")
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                    Spacer()
                }
                .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredEntries) { entry in
                            MemoryEntryRow(
                                entry: entry,
                                onDelete: { onDelete(entry.id) }
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

// MARK: - Filter Chip

struct MemoryFilterChip: View {
    @Environment(\.theme) private var theme

    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? theme.accentColor : theme.tertiaryText)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? theme.accentColor.opacity(0.1) : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(
                                    isSelected ? theme.accentColor.opacity(0.3) : theme.inputBorder,
                                    lineWidth: 1
                                )
                        )
                )
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel("Filter: \(label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Memory Entry Row

struct MemoryEntryRow: View {
    @Environment(\.theme) private var theme

    let entry: MemoryEntry
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.type.displayName)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(memoryTypeColor(entry.type))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(memoryTypeColor(entry.type).opacity(0.12))
                    )

                Text(String(format: "%.0f%%", entry.confidence * 100))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)

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

            Text(entry.content)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .lineLimit(3)

            HStack(spacing: 6) {
                if !entry.tags.isEmpty {
                    ForEach(entry.tags.prefix(3), id: \.self) { tag in
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
                Text(entry.createdAt)
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
            "\(entry.type.displayName) memory: \(entry.content). Confidence \(Int(entry.confidence * 100)) percent"
        )
        .accessibilityHint("Hover to reveal delete option")
    }
}

func memoryTypeColor(_ type: MemoryEntryType) -> Color {
    switch type {
    case .fact: return .blue
    case .preference: return .purple
    case .decision: return .green
    case .correction: return .orange
    case .commitment: return .red
    case .relationship: return .cyan
    case .skill: return .indigo
    }
}

// MARK: - Summary Row

struct MemorySummaryRow: View {
    @Environment(\.theme) private var theme

    let summary: ConversationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(summary.tokenCount) tokens")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)

                Spacer()

                Text(summary.conversationAt)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            Text(summary.summary)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Conversation summary: \(summary.summary). \(summary.tokenCount) tokens, \(summary.conversationAt)"
        )
    }
}
