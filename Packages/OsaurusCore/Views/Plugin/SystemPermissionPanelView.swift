//
//  SystemPermissionPanelView.swift
//  osaurus
//
//  The card `SystemPermissionPanelService` shows when a tool needs a macOS
//  permission that macOS will not ask for itself.
//

import SwiftUI

struct SystemPermissionPanelView: View {
    let request: SystemPermissionPanelService.Request
    @ObservedObject var model: SystemPermissionPanelModel
    let onOpenSettings: () -> Void
    let onTryAgain: () -> Void
    let onNotNow: () -> Void

    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s0) {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                header
                Text(verbatim: Self.explanation(for: request))
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("systemPermissionPanel.explanation")
                Text(verbatim: model.stillOff ? Self.stillOffLine : Self.nextStepLine)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(model.stillOff ? theme.status.warning.foreground : theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("systemPermissionPanel.nextStep")
            }
            .padding(theme.settingsSheetInset)

            ThemeHairlineDivider(color: theme.border.default)
            footer
        }
        .frame(width: SettingsSheetWidth.compact)
        .fixedSize(horizontal: true, vertical: true)
        .clipShape(RoundedRectangle(cornerRadius: theme.radius.xlarge, style: .continuous))
        .settingsChrome(.overlay)
        .environment(\.theme, themeManager.currentTheme)
    }

    private var header: some View {
        HStack(spacing: theme.space.s12) {
            Image(systemName: request.permission.systemIconName)
                .glyphSize(.medium, weight: .semibold)
                .foregroundColor(theme.text.secondary)
                .frame(width: theme.space.s32 + theme.space.s4, height: theme.space.s32 + theme.space.s4)
                .settingsChrome(.subtle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.settingsTitleToDescription) {
                Text(verbatim: Self.title(for: request))
                    .font(SettingsFont.cardTitle)
                    .foregroundColor(theme.text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: L("For \(request.toolName)"))
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("systemPermissionPanel.title")
    }

    private var footer: some View {
        HStack(spacing: theme.settingsControlGap) {
            SettingsButton(.tertiary, "Not Now", help: L("Esc"), action: onNotNow)
                .accessibilityIdentifier("systemPermissionPanel.notNow")
            Spacer(minLength: theme.space.s8)
            SettingsButton(.secondary, model.isChecking ? "Checking…" : "Try Again", action: onTryAgain)
                .disabled(model.isChecking)
                .accessibilityIdentifier("systemPermissionPanel.tryAgain")
            SettingsButton(.primary, "Open System Settings", help: L("Return"), action: onOpenSettings)
                .accessibilityIdentifier("systemPermissionPanel.openSettings")
        }
        .padding(.horizontal, theme.settingsSheetInset)
        .padding(.vertical, theme.space.s16)
        .background(theme.surface.subtle)
    }

    // MARK: - Copy

    static func title(for request: SystemPermissionPanelService.Request) -> String {
        L("\(request.requesterName) needs \(request.permission.displayName) access")
    }

    static func explanation(for request: SystemPermissionPanelService.Request) -> String {
        let path = request.permission.systemSettingsPath
        switch request.reason {
        case .turnedOff:
            return L("It is turned off for Osaurus in System Settings → Privacy & Security → \(path).")
        case .settingsOnly:
            return L("macOS does not ask for this one. Turn on Osaurus in System Settings → Privacy & Security → \(path).")
        case .addOnly:
            return L(
                "Osaurus can add events but not read them. In System Settings → Privacy & Security → Calendars, choose Full Access for Osaurus."
            )
        }
    }

    static let nextStepLine = L("Then come back here. The request goes ahead once access is on.")
    static let stillOffLine = L("It is still off. Turn on Osaurus in System Settings, then try again.")
}
