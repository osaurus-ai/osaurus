//
//  SettingsPermissionRow.swift
//  osaurus
//
//  One macOS permission as a settings row: icon tile, name, description,
//  status chip, and Grant / Settings, with an optional diagnostic Test.
//  Shared by Permissions and Computer & Browser Use.
//

import SwiftUI

struct SettingsPermissionRow: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme.catalogFamily(52, enabled: inspectionEnabled) }
    @ObservedObject private var permissionService = SystemPermissionService.shared

    let permission: SystemPermission
    /// Shows "Optional" instead of "Not Granted" while ungranted.
    var isOptional: Bool = false
    /// Already-localized; defaults to the permission's own description.
    var description: String?
    /// Adds a Test button that runs `SystemPermissionService.probe`.
    var showsTest: Bool = false

    @State private var isTesting = false
    @State private var testResult: PermissionProbeResult?

    private var isGranted: Bool {
        permissionService.permissionStates[permission] ?? false
    }

    private var status: (text: String, tone: StatusChip.Tone) {
        if isGranted { return (L("Granted"), .success) }
        return isOptional ? (L("Optional"), .neutral) : (L("Not Granted"), .warning)
    }

    var body: some View {
        Group {

        VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.52.elements.layout.settingsPermissionRow.body.verticalGap", inheriting: theme.space.s12)) {
            SettingsRow(
                title: permission.displayName,
                description: description ?? permission.description,
                verbatimTitle: true,
                verbatimDescription: true
            ) {
                SettingsIconTile(
                    icon: permission.systemIconName,
                    tint: isGranted ? theme.status.success.foreground : theme.text.tertiary
                )
            } trailing: {
                HStack(spacing: theme.catalogLayoutMetric("component.library.52.elements.layout.settingsPermissionRow.body.horizontalGap", inheriting: theme.space.s8)) {
                    StatusChip(status.text, tone: status.tone)
                    if showsTest {
                        SettingsButton(
                            .secondary,
                            "Test",
                            isLoading: isTesting,
                            size: .compact,
                            help: "Run a diagnostic test to verify permission",
                            action: runTest
                        )
                    }
                    if isGranted {
                        SettingsButton(.secondary, "Settings", icon: "gear", size: .compact) {
                            permissionService.openSystemSettings(for: permission)
                        }
                    } else {
                        SettingsButton(.primary, "Grant", icon: "hand.raised", size: .compact) {
                            permissionService.requestPermission(permission)
                        }
                    }
                }.catalogLayoutTarget("component.library.52.elements.layout.settingsPermissionRow.body.horizontalGap")
            }

            if let testResult {
                testResultView(testResult)
            }
        }.catalogLayoutTarget("component.library.52.elements.layout.settingsPermissionRow.body.verticalGap")
    
        }.environment(\.theme, theme)
}

    private func testResultView(_ result: PermissionProbeResult) -> some View {
        // Branch on the probe's decision, not its localized text
        // (`SUCCESS:` is `ERFOLG:` in German — #2858).
        let kind: ThemeStatusKind = result.isGranted ? .success : .warning
        let tint = theme.status[kind].foreground
        return HStack(alignment: .top, spacing: theme.catalogLayoutMetric("component.library.52.elements.layout.settingsPermissionRow.testResultView.horizontalGap", inheriting: theme.space.s6)) {
            Image(systemName: result.isGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .catalogTypography(.caption, theme: theme, fallback: SettingsFont.glyphSmall)
                .foregroundColor(tint)
                .padding(.top, theme.space.s2)
            VStack(alignment: .leading, spacing: theme.catalogLayoutMetric("component.library.52.elements.layout.settingsPermissionRow.testResultView.verticalGap", inheriting: theme.space.s2)) {
                Text(result.message)
                    .catalogTypography(.code, theme: theme, fallback: SettingsFont.monoSmall)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .foregroundColor(tint)
                if !result.isGranted {
                    Text(
                        "Xcode builds need separate grants. Try 'tccutil reset AppleEvents' if stuck.",
                        bundle: .module
                    )
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                }
            }.catalogLayoutTarget("component.library.52.elements.layout.settingsPermissionRow.testResultView.verticalGap")
        }.catalogLayoutTarget("component.library.52.elements.layout.settingsPermissionRow.testResultView.horizontalGap")
        .padding(.horizontal, theme.catalogLayoutMetric("component.library.52.elements.layout.settingsPermissionRow.testResultView.padding.horizontal", inheriting: theme.space.s12)).padding(.vertical, theme.catalogLayoutMetric("component.library.52.elements.layout.settingsPermissionRow.testResultView.padding.vertical", inheriting: theme.space.s12)).catalogLayoutTarget("component.library.52.elements.layout.settingsPermissionRow.testResultView.padding.horizontal").catalogLayoutTarget("component.library.52.elements.layout.settingsPermissionRow.testResultView.padding.vertical")
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.status(kind))
    }

    private func runTest() {
        guard !isTesting else { return }
        isTesting = true
        testResult = nil

        Task.detached(priority: .userInitiated) {
            // Automation probes launch the target app in the background
            // first so the Apple Event does not bring it to the front.
            if let bundleId = SystemPermissionService.automationProbeBundleIdentifier(for: permission) {
                _ = await AppleScriptBridge.ensureRunning(bundleIdentifier: bundleId, appName: permission.displayName)
            }
            let result = await SystemPermissionService.probe(permission)

            await MainActor.run {
                testResult = result
                isTesting = false
                // The probe is the live truth for this permission: a success
                // proves the grant, a failure means the cached state is stale.
                permissionService.updatePermissionState(permission, isGranted: result.isGranted)
            }
        }
    }
}
