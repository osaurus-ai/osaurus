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

    @StateObject private var themeManager = ThemeManager.shared

    /// Use computed property to always get the current theme from ThemeManager
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var copied = false
    @State private var showAlwaysAllowConfirm = false
    @State private var appeared = false

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
            // Glass background with enhanced overlay
            GlassSurface(cornerRadius: 24, material: .hudWindow)
                .allowsHitTesting(false)

            // Subtle gradient overlay for depth
            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.accentColor.opacity(0.03),
                            Color.clear,
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Header with warning icon and title
                header
                    .padding(.top, 28)
                    .padding(.horizontal, 28)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : -8)

                // Description
                if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(description)
                        .font(theme.font(size: 13, weight: .regular))
                        .foregroundColor(theme.primaryText.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.top, 12)
                        .padding(.horizontal, 32)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : -4)
                }

                // JSON arguments code block (only show if there are arguments)
                if hasArguments {
                    argumentsBlock
                        .padding(.top, 18)
                        .padding(.horizontal, 24)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 4)
                }

                // Action buttons
                actionButtons
                    .padding(.top, 22)
                    .padding(.bottom, 24)
                    .padding(.horizontal, 24)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 8)
            }
        }
        .frame(width: 460)
        .fixedSize(horizontal: true, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.15),
                            Color.white.opacity(0.05),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .onAppear {
            // Entrance animation
            withAnimation(theme.springAnimation(responseMultiplier: 1.25).delay(0.05)) {
                appeared = true
            }
        }
        .environment(\.theme, themeManager.currentTheme)
        .alert("Always Allow \"\(toolName)\"?", isPresented: $showAlwaysAllowConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Always Allow") {
                onAlwaysAllow()
            }
        } message: {
            Text(
                "This tool will be automatically allowed to run without prompting in the future. You can change this in the Tools settings."
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 14) {
            // Calm icon with soft blue treatment
            ZStack {
                // Subtle outer glow
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                theme.accentColor.opacity(0.12),
                                theme.accentColor.opacity(0.03),
                                Color.clear,
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: 40
                        )
                    )
                    .frame(width: 72, height: 72)

                // Inner filled circle
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.15),
                                theme.accentColor.opacity(0.08),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)

                // Border ring
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.35),
                                theme.accentColor.opacity(0.15),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                    .frame(width: 52, height: 52)

                // Icon - neutral terminal icon
                Image(systemName: "terminal.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                theme.accentColor,
                                theme.accentColor.opacity(0.8),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            // Title
            VStack(spacing: 6) {
                Text("APPROVE ACTION")
                    .font(theme.font(size: 10, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(1.5)

                Text(toolName)
                    .font(theme.font(size: 17, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
        }
    }

    // MARK: - Arguments Block

    private var argumentsBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "curlybraces")
                        .font(theme.font(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)

                    Text("ARGUMENTS")
                        .font(theme.font(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .tracking(0.8)
                }

                Spacer()

                // Copy button with refined styling
                Button(action: copyArguments) {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(theme.font(size: 9, weight: .semibold))
                        Text(copied ? "Copied" : "Copy")
                            .font(theme.font(size: 10, weight: .medium))
                    }
                    .foregroundColor(copied ? theme.successColor : theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule()
                            .fill(theme.tertiaryBackground.opacity(0.8))
                    )
                    .overlay(
                        Capsule()
                            .stroke(
                                copied ? theme.successColor.opacity(0.3) : theme.primaryBorder.opacity(0.5),
                                lineWidth: 0.5
                            )
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .contentShape(Capsule())
            }

            // Code block with enhanced styling
            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                Text(prettyArguments)
                    .font(theme.monoFont(size: 11.5))
                    .foregroundColor(theme.primaryText.opacity(0.9))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.codeBlockBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(theme.primaryBorder.opacity(0.6), lineWidth: 1)
            )
            .overlay(
                // Subtle inner shadow at top
                RoundedRectangle(cornerRadius: 12)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.black.opacity(0.05),
                                Color.clear,
                            ],
                            startPoint: .top,
                            endPoint: .center
                        )
                    )
                    .allowsHitTesting(false)
            )
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                // Deny button (secondary)
                PermissionButton(
                    title: "Deny",
                    shortcutHint: "esc",
                    icon: "xmark",
                    isPrimary: false,
                    color: theme.errorColor,
                    action: onDeny
                )

                // Allow button (primary)
                PermissionButton(
                    title: "Allow",
                    shortcutHint: "return",
                    icon: "checkmark",
                    isPrimary: true,
                    color: theme.successColor,
                    action: onAllow
                )
            }

            // Always Allow button (tertiary)
            AlwaysAllowButton(action: { showAlwaysAllowConfirm = true })
        }
    }

    // MARK: - Actions

    private func copyArguments() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prettyArguments, forType: .string)
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

// MARK: - Permission Button

private struct PermissionButton: View {
    let title: String
    let shortcutHint: String
    let icon: String
    let isPrimary: Bool
    let color: Color
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var isPressed = false
    @State private var isHovering = false

    // Color for button text - full opacity for better visibility
    private var displayColor: Color {
        return color
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(theme.font(size: 13, weight: isPrimary ? .semibold : .medium))
                    Text(title)
                        .font(theme.font(size: 13, weight: isPrimary ? .semibold : .medium))
                }
                .foregroundColor(isPrimary ? .white : displayColor)

                // Keyboard shortcut hint
                KeyboardShortcutBadge(shortcut: shortcutHint, isPrimary: isPrimary, color: displayColor)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isPrimary {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        color,
                                        color.opacity(0.85),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.25),
                                                Color.white.opacity(0.05),
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        ),
                                        lineWidth: 1
                                    )
                            )
                    } else {
                        // Visible tinted background for deny button
                        RoundedRectangle(cornerRadius: 12)
                            .fill(color.opacity(isHovering ? 0.18 : 0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        color.opacity(isPressed ? 0.6 : (isHovering ? 0.5 : 0.4)),
                                        lineWidth: 1.5
                                    )
                            )
                    }
                }
            )
            .shadow(
                color: isPrimary
                    ? color.opacity(isHovering ? 0.3 : 0.2) : Color.clear,
                radius: isHovering ? 10 : 5,
                x: 0,
                y: isHovering ? 3 : 1
            )
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(theme.springAnimation(responseMultiplier: 0.6, dampingMultiplier: 0.9), value: isPressed)
        .animation(theme.animationQuick(), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .onLongPressGesture(
            minimumDuration: .infinity,
            maximumDistance: .infinity,
            pressing: { pressing in
                isPressed = pressing
            },
            perform: {}
        )
    }
}

// MARK: - Keyboard Shortcut Badge

private struct KeyboardShortcutBadge: View {
    let shortcut: String
    let isPrimary: Bool
    let color: Color

    @Environment(\.theme) private var theme

    var body: some View {
        Text(shortcut)
            .font(theme.font(size: 9, weight: .medium))
            .foregroundColor(isPrimary ? Color.white.opacity(0.7) : color.opacity(0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(isPrimary ? Color.white.opacity(0.15) : color.opacity(0.1))
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
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle")
                    .font(theme.font(size: 11, weight: .medium))
                Text("Always Allow")
                    .font(theme.font(size: 12, weight: .medium))
            }
            .foregroundColor(isHovered ? theme.primaryText : theme.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(theme.secondaryBackground.opacity(isHovered ? 0.8 : 0.5))
            )
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            withAnimation(theme.animationQuick()) {
                isHovered = hovering
            }
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
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
