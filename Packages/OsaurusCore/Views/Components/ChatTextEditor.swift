//
//  ChatTextEditor.swift
//  osaurus
//
//  Glass-effect input field with backdrop blur and accent glow
//

import SwiftUI

// MARK: - SwiftUI TextEditor-based Chat Input
struct ChatTextEditor: View {
    @Binding var text: String
    var placeholder: String = "Message…"
    @Binding var isFocused: Bool
    var onSend: () -> Void
    @FocusState private var internalFocus: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .focused($internalFocus)
                .onChange(of: internalFocus) { _, v in
                    if v != isFocused { isFocused = v }
                }

            if text.isEmpty && !internalFocus {
                Text(placeholder)
                    .font(.system(size: 15))
                    .foregroundColor(Color.secondary.opacity(0.8))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: isFocused) { _, v in
            if v != internalFocus { internalFocus = v }
        }
        .frame(minHeight: 48, maxHeight: 120)
    }
}
