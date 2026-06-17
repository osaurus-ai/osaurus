//
//  ComputerUseSettingsView.swift
//  OsaurusCore — Computer Use
//
//  Settings panel for the Computer Use feature. PR1 surfaces what the
//  feature does, the local-first consent model (reads/navigation run
//  automatically; edits and anything consequential pause for approval),
//  the system-permission status it depends on, and how to enable it per
//  agent. PR2 layers the autonomy-policy editor on top of this panel.
//

import SwiftUI

struct ComputerUseSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared
    @ObservedObject private var cloudVisionConsent = CloudVisionConsent.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false

    /// The editable autonomy policy, loaded from `ComputerUsePolicyStore` on
    /// appear and persisted on every change.
    @State private var policy: AutonomyPolicy = .defaultPolicy
    @State private var newOverrideApp: String = ""
    @State private var newAllowlistApp: String = ""

    /// Accessibility is required for the ax-mode loop; Screen Recording is
    /// optional today and only needed once SOM/Vision capture tiers ship.
    private let requiredPermissions: [SystemPermission] = [.accessibility]
    private let optionalPermissions: [SystemPermission] = [.screenRecording]

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    aboutCard
                    consentCard
                    policyCard

                    permissionSection(
                        title: L("Required Permissions"),
                        permissions: requiredPermissions
                    )

                    permissionSection(
                        title: L("Optional Permissions"),
                        permissions: optionalPermissions,
                        footnote: L(
                            "Screen Recording is only needed for screenshot-based perception (the som/vision tiers). The accessibility loop works without it."
                        )
                    )

                    cloudVisionCard
                    enableCard
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
            policy = ComputerUsePolicyStore.load()
            permissionService.startPeriodicRefresh(interval: 2.0)
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .onDisappear {
            permissionService.stopPeriodicRefresh()
        }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Computer Use"),
            subtitle: L("Let agents operate macOS apps on your behalf")
        ) {
            HeaderSecondaryButton("Refresh", icon: "arrow.clockwise") {
                permissionService.refreshAllPermissions()
            }
            .localizedHelp("Refresh permission status")
        }
    }

    // MARK: - Cards

    private var aboutCard: some View {
        infoCard(icon: "cursorarrow.rays", title: L("About Computer Use")) {
            Text(
                "When enabled for an agent, Computer Use gives it a single tool that drives macOS apps through the accessibility tree — reading on-screen elements, clicking, typing, and verifying each step. It runs as a self-contained sub-agent: you give it a goal and it works through the steps on its own, surfacing every action in a live activity feed.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var consentCard: some View {
        infoCard(icon: "hand.raised.fill", title: L("Local-first consent")) {
            VStack(alignment: .leading, spacing: 8) {
                consentRow(
                    icon: "checkmark.circle.fill",
                    color: theme.successColor,
                    text: L("Reads and navigation (looking, finding, clicking, scrolling) run automatically.")
                )
                consentRow(
                    icon: "questionmark.circle.fill",
                    color: theme.warningColor,
                    text: L(
                        "Edits and anything consequential (typing, changing values, pressing keys) pause for your approval before they run."
                    )
                )
                consentRow(
                    icon: "stop.circle.fill",
                    color: theme.accentColor,
                    text: L("You can stop a run at any time from the activity feed in the chat.")
                )
            }
        }
    }

    // MARK: - Policy card

    private var policyCard: some View {
        infoCard(icon: "slider.horizontal.3", title: L("Autonomy policy")) {
            VStack(alignment: .leading, spacing: 18) {
                Text(
                    "Decide what runs automatically, what pauses for your approval, and what is blocked. The strictest of the global default, any per-app override, and the agent's own ceiling always wins.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                globalPresetSection
                Divider().background(theme.cardBorder)
                perAppSection
                Divider().background(theme.cardBorder)
                allowlistSection
            }
        }
    }

    private var globalPresetSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Default for all apps"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
            HStack(spacing: 10) {
                presetPickerMenu(
                    Binding(
                        get: { policy.globalPreset },
                        set: {
                            policy.globalPreset = $0
                            persist()
                        }
                    )
                )
                Text(policy.globalPreset.detail)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var perAppSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Per-app overrides"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(
                "Hold a specific app to a stricter stance than your default. Overrides can only add caution, never remove it.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(sortedOverrideKeys, id: \.self) { appKey in
                HStack(spacing: 10) {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                    Text(appKey)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                    presetPickerMenu(
                        Binding(
                            get: { policy.perApp[appKey] ?? .cautious },
                            set: {
                                policy.perApp[appKey] = $0
                                persist()
                            }
                        )
                    )
                    Button(action: { removeOverride(appKey) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(theme.errorColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .localizedHelp("Remove override")
                }
                .padding(.vertical, 2)
            }

            appAddRow(
                placeholder: L("App name (e.g. Mail)"),
                text: $newOverrideApp,
                action: addOverride
            )
        }
    }

    private var allowlistSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("App allowlist"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(
                "Leave empty to allow Computer Use in any app. Add apps to restrict it to ONLY those — every other app is blocked before any action.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

            ForEach(policy.allowlist ?? [], id: \.self) { app in
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 12))
                        .foregroundColor(theme.successColor)
                    Text(app)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                    Button(action: { removeAllowlisted(app) }) {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(theme.errorColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .localizedHelp("Remove from allowlist")
                }
                .padding(.vertical, 2)
            }

            appAddRow(
                placeholder: L("App name to allow"),
                text: $newAllowlistApp,
                action: addAllowlisted
            )
        }
    }

    // MARK: - Policy helpers

    private var sortedOverrideKeys: [String] {
        policy.perApp.keys.sorted()
    }

    @ViewBuilder
    private func presetPickerMenu(_ selection: Binding<AutonomyPreset>) -> some View {
        Menu {
            ForEach(AutonomyPreset.allCases) { preset in
                Button {
                    selection.wrappedValue = preset
                } label: {
                    if preset == selection.wrappedValue {
                        Label(preset.displayLabel, systemImage: "checkmark")
                    } else {
                        Text(preset.displayLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selection.wrappedValue.displayLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private func appAddRow(placeholder: String, text: Binding<String>, action: @escaping () -> Void)
        -> some View
    {
        HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .textFieldStyle(PlainTextFieldStyle())
                .font(.system(size: 12))
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
                .onSubmit(action)
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                    Text(L("Add"))
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.tertiaryBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private func persist() {
        if let list = policy.allowlist, list.isEmpty { policy.allowlist = nil }
        ComputerUsePolicyStore.save(policy)
    }

    private func addOverride() {
        let name = newOverrideApp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        policy.perApp[AutonomyPolicy.normalize(name)] = .cautious
        newOverrideApp = ""
        persist()
    }

    private func removeOverride(_ key: String) {
        policy.perApp.removeValue(forKey: key)
        persist()
    }

    private func addAllowlisted() {
        let name = newAllowlistApp.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let normalized = AutonomyPolicy.normalize(name)
        var list = policy.allowlist ?? []
        if !list.contains(where: { AutonomyPolicy.normalize($0) == normalized }) {
            list.append(normalized)
        }
        policy.allowlist = list
        newAllowlistApp = ""
        persist()
    }

    private func removeAllowlisted(_ app: String) {
        policy.allowlist?.removeAll { $0 == app }
        persist()
    }

    private var cloudVisionCard: some View {
        infoCard(icon: "cloud", title: L("Cloud vision")) {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "By default, perception is local-only: the accessibility tree and any screenshots stay on this Mac. If your agent uses a cloud model, you can let Computer Use send it screenshots for the rare cases the accessibility tree can't carry — but only after every detected piece of sensitive text is masked first.",
                    bundle: .module
                )
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Allow scrubbed screenshots to reach a cloud model"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Text(
                            "Off by default. Screenshots are never sent without this and without on-device masking.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { cloudVisionConsent.isPersistentlyGranted },
                            set: { cloudVisionConsent.setPersistent($0) }
                        )
                    )
                    .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                    .labelsHidden()
                }
            }
        }
    }

    private var enableCard: some View {
        infoCard(icon: "person.2.fill", title: L("Enabling Computer Use")) {
            Text(
                "Computer Use is off by default and is enabled per agent (custom agents only). Open the Agents tab, select an agent, and turn on Computer Use under Features. The Default agent cannot use this capability.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func consentRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(color)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Permission section

    @ViewBuilder
    private func permissionSection(
        title: String,
        permissions: [SystemPermission],
        footnote: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.secondaryText)

            ForEach(permissions, id: \.rawValue) { permission in
                ComputerUsePermissionRow(permission: permission)
            }

            if let footnote {
                Text(footnote)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Generic card shell

    @ViewBuilder
    private func infoCard<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(theme.accentColor)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}

// MARK: - Compact permission row

/// A compact status + action row for a single system permission. Lighter
/// than `PermissionsView`'s row (no diagnostic test button) since this
/// panel only needs to show grant status and route to System Settings.
private struct ComputerUsePermissionRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared
    let permission: SystemPermission

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var isGranted: Bool {
        permissionService.permissionStates[permission] ?? false
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isGranted ? theme.successColor.opacity(0.12) : theme.tertiaryBackground)
                Image(systemName: permission.systemIconName)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isGranted ? theme.successColor : theme.secondaryText)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(permission.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text(isGranted ? L("Granted") : L("Not Granted"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(isGranted ? theme.successColor : theme.warningColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(
                                    (isGranted ? theme.successColor : theme.warningColor).opacity(0.1)
                                )
                        )
                }
                Text(permission.description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }

            Spacer()

            if isGranted {
                Button(action: { permissionService.openSystemSettings(for: permission) }) {
                    actionLabel(icon: "gear", title: L("Settings"), filled: false)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Button(action: { permissionService.requestPermission(permission) }) {
                    actionLabel(icon: "hand.raised", title: L("Grant"), filled: true)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.inputBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(
                            isGranted ? theme.successColor.opacity(0.3) : theme.inputBorder,
                            lineWidth: 1
                        )
                )
        )
    }

    @ViewBuilder
    private func actionLabel(icon: String, title: String, filled: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
            Text(title)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundColor(filled ? .white : theme.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(filled ? theme.accentColor : theme.tertiaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(filled ? Color.clear : theme.inputBorder, lineWidth: 1)
                )
        )
    }
}
