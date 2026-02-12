//
//  PermissionsView.swift
//  osaurus
//
//  System permissions management view.
//

import SwiftUI

// MARK: - Permissions View

struct PermissionsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            // Scrollable content area
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Info card
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(theme.accentColor)

                            Text("About System Permissions")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(theme.primaryText)
                        }

                        Text(
                            "Some plugins require additional system permissions to function. Grant permissions below to enable advanced features like automation, calendar access, and more."
                        )
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(theme.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(theme.cardBorder, lineWidth: 1)
                            )
                    )

                    // Permissions list
                    VStack(spacing: 10) {
                        ForEach(SystemPermission.allCases, id: \.rawValue) { permission in
                            SystemPermissionRow(permission: permission)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            permissionService.startPeriodicRefresh(interval: 2.0)
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .onDisappear {
            permissionService.stopPeriodicRefresh()
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: "Permissions",
            subtitle: "Manage system permissions for plugins and features"
        ) {
            HeaderSecondaryButton("Refresh", icon: "arrow.clockwise") {
                permissionService.refreshAllPermissions()
            }
            .help("Refresh permission status")
        }
    }
}

// MARK: - System Permission Row

private struct SystemPermissionRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared
    let permission: SystemPermission

    @State private var isTesting = false
    @State private var testResult: String? = nil
    @State private var isHovered = false

    private var isGranted: Bool {
        permissionService.permissionStates[permission] ?? false
    }

    // Only automation permissions support the diagnostic test
    private var canTest: Bool {
        permission == .automation || permission == .automationCalendar || permission == .contacts
            || permission == .calendar || permission == .reminders || permission == .location || permission == .notes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                // Permission icon with gradient background
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            LinearGradient(
                                colors: isGranted
                                    ? [
                                        themeManager.currentTheme.successColor.opacity(0.15),
                                        themeManager.currentTheme.successColor.opacity(0.05),
                                    ]
                                    : [
                                        themeManager.currentTheme.tertiaryBackground,
                                        themeManager.currentTheme.tertiaryBackground.opacity(0.8),
                                    ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: permission.systemIconName)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(
                            isGranted ? themeManager.currentTheme.successColor : themeManager.currentTheme.secondaryText
                        )
                }
                .frame(width: 40, height: 40)

                // Permission info
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(permission.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(themeManager.currentTheme.primaryText)

                        // Status badge
                        Text(isGranted ? "Granted" : "Not Granted")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(
                                isGranted
                                    ? themeManager.currentTheme.successColor : themeManager.currentTheme.warningColor
                            )
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(
                                        isGranted
                                            ? themeManager.currentTheme.successColor.opacity(0.1)
                                            : themeManager.currentTheme.warningColor.opacity(0.1)
                                    )
                            )
                    }

                    Text(permission.description)
                        .font(.system(size: 11))
                        .foregroundColor(themeManager.currentTheme.tertiaryText)
                        .lineLimit(2)
                }

                Spacer()

                HStack(spacing: 8) {
                    // Test Button (for automation permissions)
                    if canTest {
                        Button(action: runTest) {
                            if isTesting {
                                ProgressView()
                                    .scaleEffect(0.6)
                                    .frame(width: 12, height: 12)
                            } else {
                                Text("Test")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .foregroundColor(themeManager.currentTheme.primaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(themeManager.currentTheme.tertiaryBackground)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                                )
                        )
                        .buttonStyle(PlainButtonStyle())
                        .disabled(isTesting)
                        .help("Run a diagnostic test to verify permission")
                    }

                    // Action button
                    if isGranted {
                        Button(action: {
                            permissionService.openSystemSettings(for: permission)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "gear")
                                    .font(.system(size: 11))
                                Text("Settings")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(themeManager.currentTheme.secondaryText)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(themeManager.currentTheme.tertiaryBackground)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(themeManager.currentTheme.inputBorder, lineWidth: 1)
                                    )
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    } else {
                        Button(action: {
                            permissionService.requestPermission(permission)
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "hand.raised")
                                    .font(.system(size: 11))
                                Text("Grant")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(themeManager.currentTheme.accentColor)
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
            }

            // Inline Test Result
            if let result = testResult {
                let isSuccess = result.hasPrefix("SUCCESS")
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(
                            isSuccess ? themeManager.currentTheme.successColor : themeManager.currentTheme.warningColor
                        )
                        .padding(.top, 1)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(result)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(4)
                            .textSelection(.enabled)
                            .foregroundColor(
                                isSuccess
                                    ? themeManager.currentTheme.successColor : themeManager.currentTheme.warningColor
                            )

                        if !isSuccess {
                            Text("Xcode builds need separate grants. Try 'tccutil reset AppleEvents' if stuck.")
                                .font(.system(size: 10))
                                .foregroundColor(themeManager.currentTheme.tertiaryText)
                                .padding(.top, 2)
                        }
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            (isSuccess
                                ? themeManager.currentTheme.successColor : themeManager.currentTheme.warningColor)
                                .opacity(0.1)
                        )
                )
                .padding(.leading, 52)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(themeManager.currentTheme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isGranted
                                ? themeManager.currentTheme.successColor.opacity(0.3)
                                : themeManager.currentTheme.inputBorder,
                            lineWidth: 1
                        )
                )
        )
        .scaleEffect(isHovered ? 1.005 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private func runTest() {
        guard !isTesting else { return }
        isTesting = true
        testResult = nil

        Task.detached(priority: .userInitiated) {
            let result: String
            if permission == .automationCalendar {
                result = await SystemPermissionService.debugTestCalendarAccess()
            } else if permission == .calendar {
                result = SystemPermissionService.debugTestCalendarEventKitAccess()
            } else if permission == .reminders {
                result = SystemPermissionService.debugTestRemindersAccess()
            } else if permission == .location {
                result = SystemPermissionService.debugTestLocationAccess()
            } else if permission == .notes {
                result = SystemPermissionService.debugTestNotesAccess()
            } else if permission == .automation {
                result = SystemPermissionService.debugTestAutomationAccess()
            } else if permission == .contacts {
                result = SystemPermissionService.debugTestContactsAccess()
            } else {
                result = "Test not available"
            }

            await MainActor.run {
                testResult = result
                isTesting = false

                // Update permission state if test succeeded
                if result.hasPrefix("SUCCESS") {
                    permissionService.updatePermissionState(permission, isGranted: true)
                }
            }
        }
    }
}

#Preview {
    PermissionsView()
}
