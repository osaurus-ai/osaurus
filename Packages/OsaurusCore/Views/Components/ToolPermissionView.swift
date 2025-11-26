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

    @StateObject private var themeManager = ThemeManager.shared
    @State private var copied = false
    @State private var iconPulse = false

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

    var body: some View {
        ZStack {
            // Glass background
            GlassSurface(cornerRadius: 20, material: .hudWindow)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                // Header with warning icon and title
                header
                    .padding(.top, 24)
                    .padding(.horizontal, 24)

                // Description
                if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(description)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(theme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                        .padding(.horizontal, 24)
                }

                // JSON arguments code block
                argumentsBlock
                    .padding(.top, 16)
                    .padding(.horizontal, 24)

                // Action buttons
                actionButtons
                    .padding(.top, 20)
                    .padding(.bottom, 24)
                    .padding(.horizontal, 24)
            }
        }
        .frame(width: 480)
        .fixedSize(horizontal: true, vertical: true)
        .onAppear {
            // Start subtle icon animation
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                iconPulse = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            // Animated warning icon
            ZStack {
                Circle()
                    .fill(theme.warningColor.opacity(0.15))
                    .frame(width: 56, height: 56)
                    .scaleEffect(iconPulse ? 1.08 : 1.0)

                Circle()
                    .stroke(theme.warningColor.opacity(0.3), lineWidth: 1.5)
                    .frame(width: 56, height: 56)
                    .scaleEffect(iconPulse ? 1.12 : 1.0)
                    .opacity(iconPulse ? 0.5 : 0.8)

                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundColor(theme.warningColor)
            }

            // Title
            VStack(spacing: 4) {
                Text("Tool Permission Request")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .textCase(.uppercase)
                    .tracking(0.8)

                Text(toolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
        }
    }

    // MARK: - Arguments Block

    private var argumentsBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Arguments")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .textCase(.uppercase)
                    .tracking(0.5)

                Spacer()

                // Copy button
                Button(action: copyArguments) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(copied ? theme.successColor : theme.secondaryText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(theme.tertiaryBackground)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }

            // Code block
            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                Text(prettyArguments)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 200)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.codeBlockBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(theme.primaryBorder, lineWidth: 1)
            )
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            // Deny button (secondary)
            PermissionButton(
                title: "Deny",
                icon: "xmark",
                isPrimary: false,
                color: theme.errorColor,
                theme: theme,
                action: onDeny
            )

            // Allow button (primary)
            PermissionButton(
                title: "Allow",
                icon: "checkmark",
                isPrimary: true,
                color: theme.successColor,
                theme: theme,
                action: onAllow
            )
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
    let icon: String
    let isPrimary: Bool
    let color: Color
    let theme: ThemeProtocol
    let action: () -> Void

    @State private var isPressed = false
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(isPrimary ? .white : color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                Group {
                    if isPrimary {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(color)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(color.opacity(0.8), lineWidth: 1)
                            )
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(theme.buttonBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(
                                        isPressed ? color : (isHovering ? color.opacity(0.8) : color.opacity(0.5)),
                                        lineWidth: 1.5
                                    )
                            )
                    }
                }
            )
            .shadow(
                color: isPrimary ? color.opacity(0.3) : theme.shadowColor.opacity(theme.shadowOpacity),
                radius: isHovering ? 8 : 4,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
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
