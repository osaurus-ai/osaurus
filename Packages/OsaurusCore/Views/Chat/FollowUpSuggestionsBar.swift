//
//  FollowUpSuggestionsBar.swift
//  osaurus
//
//  Renders AI-suggested follow-up questions for the most recent completed
//  turn as a stack of clickable rows above the composer. Tapping a row
//  submits it as the next user message. Purely presentational: the parent
//  owns generation (`ChatSession.maybeGenerateFollowUps`) and the send
//  callback (`ChatSession.sendFollowUp`). Renders nothing when there are no
//  suggestions, so callers can mount it unconditionally.
//

import SwiftUI

struct FollowUpSuggestionsBar: View {
    let suggestions: [String]
    let onSelect: (String) -> Void

    @Environment(\.theme) private var theme
    @State private var hoveredIndex: Int?

    var body: some View {
        if suggestions.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Follow up", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.secondaryText)
                    .padding(.bottom, 6)

                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                    if index > 0 {
                        Divider().overlay(theme.inputBorder.opacity(0.5))
                    }
                    Button {
                        onSelect(suggestion)
                    } label: {
                        HStack {
                            Text(suggestion)
                                .font(.system(size: 13))
                                .foregroundStyle(theme.primaryText)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .background(
                        (hoveredIndex == index ? theme.inputBackground : Color.clear)
                            .cornerRadius(6)
                    )
                    .onHover { hovering in
                        hoveredIndex = hovering ? index : (hoveredIndex == index ? nil : hoveredIndex)
                    }
                    .help(suggestion)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
