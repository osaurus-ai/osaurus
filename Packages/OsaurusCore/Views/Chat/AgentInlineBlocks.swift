//
//  AgentInlineBlocks.swift
//  osaurus
//
//  Inline UI blocks for the unified Chat agent loop:
//
//    - `InlineTodoBlock`   — read-only checklist parsed from the agent's
//                            most recent `todo(markdown)` call
//    - `InlineCompleteBlock` — "Task done" banner shown when the agent
//                              calls `complete(summary)` and the engine
//                              breaks the iteration loop
//
//  Both live alongside the message thread, keyed off `@Published` state
//  on `ChatSession`. They render as compact transcript-style cards
//  (no floating panels, no overlays) so the entire window collapses to
//  header + thread + input.
//
//  `clarify` used to live here too (`InlineClarifyBlock`), but it has
//  been promoted to a bottom-pinned overlay (`ClarifyPromptOverlay`)
//  that mounts through the shared `PromptQueue` alongside secret
//  prompts. See `ClarifyPromptOverlay.swift` and `PromptQueue.swift`.
//

import SwiftUI

// MARK: - Todo

struct InlineTodoBlock: View {
    let todo: AgentTodo

    @Environment(\.theme) private var theme
    @State private var isExpanded: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded { stepRows }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.secondaryBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .animation(.easeOut(duration: 0.18), value: isExpanded)
        .animation(.easeOut(duration: 0.18), value: todo.items.map(\.isDone))
    }

    private var header: some View {
        Button(action: { isExpanded.toggle() }) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .foregroundColor(theme.accentColor)

                Text("Todo")
                    .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                    .foregroundColor(theme.primaryText)

                if todo.totalCount > 0 {
                    Text("\(todo.doneCount)/\(todo.totalCount)")
                        .font(theme.font(size: CGFloat(theme.captionSize)))
                        .foregroundColor(theme.tertiaryText)
                }

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .bold))
                    .foregroundColor(theme.tertiaryText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var stepRows: some View {
        if todo.items.isEmpty {
            Text("No checklist items parsed.")
                .font(theme.font(size: CGFloat(theme.captionSize)))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        } else {
            Divider().padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(todo.items) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(item.isDone ? theme.successColor : theme.tertiaryText)
                            .frame(width: 16, alignment: .center)
                            .padding(.top, 2)

                        Text(item.text)
                            .font(theme.font(size: CGFloat(theme.bodySize)))
                            .foregroundColor(item.isDone ? theme.tertiaryText : theme.primaryText)
                            .strikethrough(item.isDone, color: theme.tertiaryText)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Complete

/// "Task done" banner. Rendered when the agent calls `complete(summary)`
/// and the engine ends the iteration loop. Cleared on the next user send.
struct InlineCompleteBlock: View {
    let summary: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(theme.successColor)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Done")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                    .foregroundColor(theme.successColor)
                    .textCase(.uppercase)

                Text(summary)
                    .font(theme.font(size: CGFloat(theme.bodySize)))
                    .foregroundColor(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.successColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.successColor.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 16)
    }
}
