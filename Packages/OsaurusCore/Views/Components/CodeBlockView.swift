//
//  CodeBlockView.swift
//  osaurus
//
//  Syntax highlighted code block with copy functionality
//

import AppKit
import SwiftUI

struct CodeBlockView: View {
    let code: String
    let language: String?
    let baseWidth: CGFloat

    @Environment(\.theme) private var theme
    @State private var copied = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            headerBar

            // Code content
            codeContent
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 0.5)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            // Language tag
            if let language, !language.isEmpty {
                Text(language.lowercased())
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            // Copy button
            Button(action: copy) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))

                    if copied {
                        Text("Copied")
                            .font(.system(size: 10, weight: .medium))
                    }
                }
                .foregroundColor(copied ? theme.successColor : theme.tertiaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(theme.tertiaryBackground.opacity(isHovered ? 1 : 0))
                )
            }
            .buttonStyle(.plain)
            .opacity(isHovered || copied ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
            .animation(.easeInOut(duration: 0.15), value: copied)
            .help("Copy code")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.codeBlockBackground.opacity(0.7))
    }

    // MARK: - Code Content

    private var codeContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(code)
                .font(Typography.code(baseWidth))
                .foregroundColor(theme.primaryText.opacity(0.95))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.codeBlockBackground)
    }

    // MARK: - Actions

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)

        withAnimation(.easeInOut(duration: 0.2)) {
            copied = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(.easeInOut(duration: 0.2)) {
                copied = false
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct CodeBlockView_Previews: PreviewProvider {
        static let sampleCode = """
            func fibonacci(_ n: Int) -> Int {
                guard n > 1 else { return n }
                return fibonacci(n - 1) + fibonacci(n - 2)
            }

            let result = fibonacci(10)
            print("Result: \\(result)")
            """

        static var previews: some View {
            VStack(spacing: 20) {
                CodeBlockView(code: sampleCode, language: "swift", baseWidth: 600)
                CodeBlockView(code: "npm install osaurus", language: "bash", baseWidth: 600)
                CodeBlockView(code: "print('Hello, World!')", language: nil, baseWidth: 600)
            }
            .padding()
            .frame(width: 600)
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
