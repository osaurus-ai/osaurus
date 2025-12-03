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
    @State private var copied = false
    @State private var iconPulse = false
    @State private var showAlwaysAllowConfirm = false
    @State private var appeared = false

    private var theme: ThemeProtocol {
        themeManager.currentTheme
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
            // Glass background with enhanced overlay
            GlassSurface(cornerRadius: 24, material: .hudWindow)
                .allowsHitTesting(false)

            // Subtle gradient overlay for depth
            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [
                            theme.warningColor.opacity(0.03),
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
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(theme.secondaryText)
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
            // Start subtle icon animation
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                iconPulse = true
            }
            // Entrance animation
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.05)) {
                appeared = true
            }
        }
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
            // Animated warning icon with refined gradient treatment
            ZStack {
                // Outer glow ring
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                theme.warningColor.opacity(0.2),
                                theme.warningColor.opacity(0.05),
                                Color.clear,
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: 40
                        )
                    )
                    .frame(width: 72, height: 72)
                    .scaleEffect(iconPulse ? 1.1 : 1.0)

                // Inner filled circle
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.warningColor.opacity(0.25),
                                theme.warningColor.opacity(0.12),
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
                                theme.warningColor.opacity(0.5),
                                theme.warningColor.opacity(0.2),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                    .frame(width: 52, height: 52)

                // Icon
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                theme.warningColor,
                                theme.warningColor.opacity(0.85),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            // Title
            VStack(spacing: 6) {
                Text("TOOL PERMISSION")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(theme.tertiaryText)
                    .tracking(1.5)

                Text(toolName)
                    .font(.system(size: 17, weight: .semibold))
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
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(theme.tertiaryText)

                    Text("ARGUMENTS")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundColor(theme.tertiaryText)
                        .tracking(0.8)
                }

                Spacer()

                // Copy button with refined styling
                Button(action: copyArguments) {
                    HStack(spacing: 5) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9, weight: .semibold))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 10, weight: .medium))
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
                    .font(.system(size: 11.5, design: .monospaced))
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
                    theme: theme,
                    action: onDeny
                )

                // Allow button (primary)
                PermissionButton(
                    title: "Allow",
                    shortcutHint: "return",
                    icon: "checkmark",
                    isPrimary: true,
                    color: theme.successColor,
                    theme: theme,
                    action: onAllow
                )
            }

            // Always Allow button (tertiary)
            Button(action: { showAlwaysAllowConfirm = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 11, weight: .medium))
                    Text("Always Allow")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
                .padding(.vertical, 4)
            }
            .buttonStyle(PlainButtonStyle())
            .opacity(0.8)
            .onHover { hovering in
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }

    // MARK: - Actions

    private func copyArguments() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prettyArguments, forType: .string)
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

// MARK: - Permission Button

private struct PermissionButton: View {
    let title: String
    let shortcutHint: String
    let icon: String
    let isPrimary: Bool
    let color: Color
    let theme: ThemeProtocol
    let action: () -> Void

    @State private var isPressed = false
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(isPrimary ? .white : color)

                // Keyboard shortcut hint
                KeyboardShortcutBadge(shortcut: shortcutHint, isPrimary: isPrimary, color: color)
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
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.buttonBackground.opacity(0.8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(
                                        isPressed ? color : (isHovering ? color.opacity(0.7) : color.opacity(0.4)),
                                        lineWidth: 1.5
                                    )
                            )
                    }
                }
            )
            .shadow(
                color: isPrimary
                    ? color.opacity(isHovering ? 0.4 : 0.25) : theme.shadowColor.opacity(theme.shadowOpacity * 0.5),
                radius: isHovering ? 12 : 6,
                x: 0,
                y: isHovering ? 4 : 2
            )
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
        .animation(.easeOut(duration: 0.2), value: isHovering)
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

    var body: some View {
        Text(shortcut)
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundColor(isPrimary ? Color.white.opacity(0.7) : color.opacity(0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(isPrimary ? Color.white.opacity(0.15) : color.opacity(0.1))
            )
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
