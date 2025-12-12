//
//  CodeBlockView.swift
//  osaurus
//
//  Syntax highlighted code block with copy functionality
//  Optimized for streaming with Equatable conformance
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

    // Precompute line count for efficiency
    private var lineCount: Int {
        code.isEmpty ? 1 : code.components(separatedBy: "\n").count
    }

    private var isMultiLine: Bool {
        lineCount > 1
    }

    private var languageIcon: String {
        switch language?.lowercased() {
        case "swift": return "swift"
        case "python", "py": return "chevron.left.forwardslash.chevron.right"
        case "javascript", "js", "typescript", "ts": return "curlybraces"
        case "json": return "doc.text"
        case "bash", "sh", "shell", "zsh": return "terminal"
        case "html", "xml": return "chevron.left.forwardslash.chevron.right"
        case "css", "scss", "sass": return "paintbrush"
        case "sql": return "cylinder"
        case "rust", "go", "java", "kotlin", "c", "cpp", "c++": return "chevron.left.forwardslash.chevron.right"
        case "markdown", "md": return "doc.richtext"
        default: return "doc.text"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            codeContent
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isHovered ? theme.primaryBorder.opacity(0.5) : theme.primaryBorder.opacity(0.25),
                    lineWidth: 0.5
                )
        )
        .shadow(
            color: theme.shadowColor.opacity(isHovered ? 0.12 : 0.06),
            radius: isHovered ? 8 : 4,
            x: 0,
            y: isHovered ? 4 : 2
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            // Language tag with icon - uses theme fonts
            if let language, !language.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: languageIcon)
                        .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                        .foregroundColor(theme.tertiaryText)

                    Text(language.lowercased())
                        .font(theme.monoFont(size: CGFloat(theme.captionSize) - 1, weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(theme.tertiaryBackground.opacity(0.6))
                )
            }

            Spacer()

            // Copy button
            Button(action: copy) {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .medium))

                    if copied {
                        Text("Copied!")
                            .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                    }
                }
                .foregroundColor(copied ? theme.successColor : theme.tertiaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(
                            copied
                                ? theme.successColor.opacity(0.15)
                                : theme.tertiaryBackground.opacity(isHovered ? 0.8 : 0)
                        )
                )
            }
            .buttonStyle(.plain)
            .opacity(isHovered || copied ? 1 : 0)
            .help("Copy code")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            theme.codeBlockBackground.opacity(0.6)
                .overlay(
                    LinearGradient(
                        colors: [
                            theme.primaryBorder.opacity(0.05),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        )
    }

    // MARK: - Code Content

    private var codeContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                // Line numbers (for multi-line code)
                if isMultiLine {
                    lineNumbersView
                }

                // Code text - uses theme code size
                Text(code)
                    .font(Typography.code(baseWidth, theme: theme))
                    .foregroundColor(theme.primaryText.opacity(0.95))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(theme.codeBlockBackground)
    }

    private var lineNumbersView: some View {
        // Use a simple Text with joined line numbers for better performance
        let numbers = (1 ... lineCount).map { String($0) }.joined(separator: "\n")
        return Text(numbers)
            .font(theme.monoFont(size: CGFloat(theme.codeSize) * Typography.scale(for: baseWidth)))
            .foregroundColor(theme.tertiaryText.opacity(0.5))
            .multilineTextAlignment(.trailing)
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 12)
            .background(
                Rectangle()
                    .fill(theme.codeBlockBackground.opacity(0.3))
            )
            .overlay(
                Rectangle()
                    .fill(theme.primaryBorder.opacity(0.15))
                    .frame(width: 1),
                alignment: .trailing
            )
    }

    // MARK: - Actions

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)

        withAnimation(theme.animationQuick()) {
            copied = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(theme.animationQuick()) {
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
                CodeBlockView(code: "print('Hello, World!')", language: "python", baseWidth: 600)
                CodeBlockView(code: "SELECT * FROM users WHERE id = 1;", language: "sql", baseWidth: 600)
            }
            .padding()
            .frame(width: 700)
            .background(Color(hex: "0f0f10"))
        }
    }
#endif
