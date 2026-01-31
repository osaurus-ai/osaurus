//
//  ToolPermissionView.swift
//  osaurus
//
//  Modern permission dialog for tool execution approval
//

import AppKit
import SwiftUI

struct ToolPermissionView: View {
    let toolName: String
    let description: String
    let argumentsJSON: String
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onAlwaysAllow: () -> Void

    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var copied = false
    @State private var showAlwaysAllowConfirm = false
    @State private var appeared = false
    @State private var alertScopeId = UUID()
    private var alertScope: ThemedAlertScope { .toolPermission(alertScopeId) }

    private var cardGradient: LinearGradient {
        let topOpacity = theme.isDark ? 0.85 : 0.9
        let bottomOpacity = theme.isDark ? 0.8 : 0.85
        return LinearGradient(
            colors: [theme.cardBackground.opacity(topOpacity), theme.cardBackground.opacity(bottomOpacity)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var prettyArguments: String {
        guard let data = argumentsJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: []),
            let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else {
            return argumentsJSON
        }
        return String(decoding: pretty, as: UTF8.self)
    }

    private var hasArguments: Bool {
        guard let data = argumentsJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: [])
        else {
            return !argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let dict = object as? [String: Any] {
            return !dict.isEmpty
        }
        if let array = object as? [Any] {
            return !array.isEmpty
        }
        return true
    }

    var body: some View {
        ZStack {
            ThemedGlassSurface(cornerRadius: 16)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(cardGradient)

            VStack(spacing: 0) {
                header
                    .padding(.top, 24)
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : -8)

                if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.top, 8)
                        .padding(.horizontal, 24)
                        .fixedSize(horizontal: false, vertical: true)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : -4)
                }

                if hasArguments {
                    argumentsBlock
                        .padding(.top, 12)
                        .padding(.horizontal, 24)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 4)
                }

                Rectangle()
                    .fill(theme.primaryBorder.opacity(0.3))
                    .frame(height: 1)
                    .padding(.top, 16)
                    .opacity(appeared ? 1 : 0)

                actionButtons
                    .padding(.top, 16)
                    .padding(.bottom, 16)
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 8)
            }
        }
        .frame(width: 380)
        .fixedSize(horizontal: true, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [theme.glassEdgeLight, theme.glassEdgeLight.opacity(0.3)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(
            color: theme.shadowColor.opacity(theme.shadowOpacity * 2),
            radius: 24,
            x: 0,
            y: 12
        )
        .onAppear {
            withAnimation(theme.springAnimation(responseMultiplier: 1.25).delay(0.05)) {
                appeared = true
            }
        }
        .environment(\.theme, themeManager.currentTheme)
        .themedAlert(
            "Always Allow \"\(toolName)\"?",
            isPresented: $showAlwaysAllowConfirm,
            message:
                "This tool will be automatically allowed to run without prompting in the future. You can change this in the Tools settings.",
            primaryButton: .primary("Always Allow") { onAlwaysAllow() },
            secondaryButton: .cancel("Cancel")
        )
        .themedAlertScope(alertScope)
        .overlay(ThemedAlertHost(scope: alertScope))
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(theme.accentColor.opacity(0.15))
                    .frame(width: 48, height: 48)

                Circle()
                    .stroke(theme.accentColor.opacity(0.3), lineWidth: 2)
                    .frame(width: 48, height: 48)
                    .scaleEffect(appeared ? 1.2 : 1)
                    .opacity(appeared ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.5).repeatForever(autoreverses: false), value: appeared)

                Image(systemName: "terminal.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }

            Text(toolName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.primaryText)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Arguments Block

    private var argumentsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Arguments", systemImage: "curlybraces")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)

                Spacer()

                Button(action: copyArguments) {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(copied ? theme.successColor : theme.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.tertiaryBackground.opacity(0.6)))
                }
                .buttonStyle(.plain)
            }

            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                Text(prettyArguments)
                    .font(theme.monoFont(size: 11.5))
                    .foregroundColor(theme.primaryText.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.codeBlockBackground))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(
                    theme.primaryBorder.opacity(0.6),
                    lineWidth: 1
                )
            )
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                PermissionButton(
                    title: "Deny",
                    shortcutHint: "esc",
                    icon: "xmark",
                    isPrimary: false,
                    color: theme.errorColor,
                    action: onDeny
                )
                PermissionButton(
                    title: "Allow",
                    shortcutHint: "return",
                    icon: "checkmark",
                    isPrimary: true,
                    color: theme.successColor,
                    action: onAllow
                )
            }
            AlwaysAllowButton(action: { showAlwaysAllowConfirm = true })
        }
    }

    private func copyArguments() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prettyArguments, forType: .string)
        withAnimation(theme.animationQuick()) { copied = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation(theme.animationQuick()) { copied = false }
        }
    }
}

// MARK: - Permission Button

private struct PermissionButton: View {
    let title: String
    let shortcutHint: String
    let icon: String
    let isPrimary: Bool
    let color: Color
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Label(title, systemImage: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(isPrimary ? (theme.isDark ? theme.primaryBackground : .white) : theme.primaryText)
                KeyboardShortcutBadge(shortcut: shortcutHint, isPrimary: isPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                isPrimary
                    ? color.opacity(isHovering ? 0.9 : 1.0) : theme.tertiaryBackground.opacity(isHovering ? 0.8 : 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(
                    isPrimary ? .clear : (isHovering ? theme.primaryBorder : theme.cardBorder),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Keyboard Shortcut Badge

private struct KeyboardShortcutBadge: View {
    let shortcut: String
    let isPrimary: Bool

    @Environment(\.theme) private var theme

    var body: some View {
        Text(shortcut)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(isPrimary ? Color.white.opacity(0.7) : theme.secondaryText.opacity(0.7))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(isPrimary ? Color.white.opacity(0.15) : theme.tertiaryBackground.opacity(0.5))
            )
    }
}

// MARK: - Always Allow Button

private struct AlwaysAllowButton: View {
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label("Always Allow", systemImage: "checkmark.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(theme.tertiaryBackground.opacity(isHovered ? 0.8 : 0.5)))
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Preview

#Preview("Tool Permission - Dark") {
    ToolPermissionView(
        toolName: "execute_code",
        description: "This tool will execute Python code on your system.",
        argumentsJSON: """
            {
                "language": "python",
                "code": "import os\\nprint(os.getcwd())",
                "timeout": 30
            }
            """,
        onAllow: { print("Allowed") },
        onDeny: { print("Denied") },
        onAlwaysAllow: { print("Always Allow") }
    )
    .environment(\.theme, DarkTheme())
    .preferredColorScheme(.dark)
    .padding(40)
    .background(Color.black.opacity(0.8))
}

#Preview("Tool Permission - Light") {
    ToolPermissionView(
        toolName: "read_file",
        description: "Read the contents of a file from disk.",
        argumentsJSON: """
            {
                "path": "/Users/example/Documents/config.json"
            }
            """,
        onAllow: { print("Allowed") },
        onDeny: { print("Denied") },
        onAlwaysAllow: { print("Always Allow") }
    )
    .environment(\.theme, LightTheme())
    .preferredColorScheme(.light)
    .padding(40)
    .background(Color.gray.opacity(0.2))
}

#Preview("Tool Permission - No Arguments") {
    ToolPermissionView(
        toolName: "list_directory",
        description: "List all files in the current working directory.",
        argumentsJSON: "{}",
        onAllow: { print("Allowed") },
        onDeny: { print("Denied") },
        onAlwaysAllow: { print("Always Allow") }
    )
    .environment(\.theme, DarkTheme())
    .preferredColorScheme(.dark)
    .padding(40)
    .background(Color.black.opacity(0.8))
}
