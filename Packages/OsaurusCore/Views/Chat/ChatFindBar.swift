//
//  ChatFindBar.swift
//  osaurus
//
//  In-conversation find bar (Cmd+F). Floats at the top-trailing edge of the
//  message thread; matches are computed per turn in ChatView and navigated
//  via the same scroll-to-turn machinery the minimap uses.
//

import SwiftUI

struct ChatFindBar: View {
    @Environment(\.theme) private var theme

    @Binding var query: String
    /// Zero-based index of the current match; meaningless when `matchCount == 0`.
    let matchIndex: Int
    let matchCount: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.tertiaryText)

            TextField(L("Find in conversation"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .frame(width: 170)
                .focused($isFieldFocused)
                .onSubmit {
                    // Enter advances; Shift+Enter is handled by the ⌃/⌄
                    // buttons since TextField can't distinguish it here.
                    onNext()
                }

            Text(matchCountLabel)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundColor(theme.tertiaryText)
                .frame(minWidth: 34)

            Divider().frame(height: 14)

            navButton(systemName: "chevron.up", action: onPrevious)
                .help(Text("Previous match", bundle: .module))
            navButton(systemName: "chevron.down", action: onNext)
                .help(Text("Next match", bundle: .module))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Close find bar", bundle: .module))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.secondaryBackground)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(theme.primaryBorder, lineWidth: 1)
        )
        .onAppear { isFieldFocused = true }
    }

    private var matchCountLabel: String {
        guard matchCount > 0 else { return query.isEmpty ? "" : "0" }
        return "\(matchIndex + 1)/\(matchCount)"
    }

    private func navButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(matchCount > 0 ? theme.primaryText : theme.tertiaryText)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(matchCount == 0)
    }
}
