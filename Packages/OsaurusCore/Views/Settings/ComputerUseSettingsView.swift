//
//  ComputerUseSettingsView.swift
//  OsaurusCore — Computer Use
//
//  Settings panel for the Computer Use feature. Organized top-down so a
//  first-time user can follow it: what the feature is, whether it's set up
//  (permissions), how to turn it on per agent, the safety model, and the
//  autonomy controls. Power-user controls (per-app overrides, app allowlist,
//  cloud vision) live under a collapsed "Advanced" section so the default
//  view stays calm. The autonomy picker shows, in plain language, exactly
//  what auto-runs, asks first, or is blocked for the selected stance.
//  Sections use the shared `SettingsSection`/`SettingsToggle` primitives.
//

import SwiftUI

// MARK: - Computer Use Tab Enum

/// Sub-tabs of the Computer Use panel. `setup` is the existing
/// permissions/autonomy content; `models` hosts the downloadable on-device
/// AppleScript models that power the `applescript` subagent.
enum ComputerUseTab: String, CaseIterable, AnimatedTabItem {
    case setup = "Setup"
    case models = "Models"

    var title: String {
        switch self {
        case .setup: return L("Setup")
        case .models: return L("Models")
        }
    }
}

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

    /// Power-user controls stay collapsed by default to keep the panel
    /// approachable for a first read.
    @State private var showAdvanced = false

    /// Sub-tab: the existing setup/permissions/autonomy cards vs the AppleScript
    /// models browser. AppleScript automation is a Computer-Use-family feature,
    /// so its downloadable models live here under a Models sub-tab.
    @State private var selectedTab: ComputerUseTab = .setup
    /// Installed curated AppleScript model count, for the Models tab badge.
    /// Refreshed on appear and whenever local models change.
    @State private var appleScriptInstalledCount = 0

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            Group {
                switch selectedTab {
                case .setup:
                    setupTab
                case .models:
                    AppleScriptModelsView()
                }
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .task { await refreshAppleScriptInstalledCount() }
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            Task { await refreshAppleScriptInstalledCount() }
        }
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

    /// The original Computer Use content: about, setup/permissions, per-agent
    /// enable steps, the consent model, screen context, and autonomy controls.
    private var setupTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                aboutCard
                setupCard
                enableCard
                    .settingsLandingAnchor("computerUse.enable")
                consentCard
                screenContextCard
                policyCard
                advancedCard
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
    }

    private func refreshAppleScriptInstalledCount() async {
        appleScriptInstalledCount = AppleScriptModelCatalog.installedModels().count
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithTabs(
            title: L("Computer Use"),
            subtitle: L("Let agents operate macOS apps on your behalf")
        ) {
            if selectedTab == .setup {
                HeaderSecondaryButton("Refresh", icon: "arrow.clockwise") {
                    permissionService.refreshAllPermissions()
                }
                .localizedHelp("Refresh permission status")
            }
        } tabsRow: {
            HeaderTabsRow(
                selection: $selectedTab,
                counts: appleScriptInstalledCount > 0 ? [.models: appleScriptInstalledCount] : nil
            )
        }
    }

    // MARK: - About card

    private var aboutCard: some View {
        SettingsSection(title: "What it is", icon: "cursorarrow.rays") {
            VStack(alignment: .leading, spacing: 12) {
                bodyText(
                    "When you turn it on for an agent, Computer Use lets that agent operate macOS apps for you — working through a goal step by step and showing every action in a live feed."
                )

                VStack(alignment: .leading, spacing: 8) {
                    aboutRow(icon: "eye", text: "Reads what's on screen to understand each app.")
                    aboutRow(icon: "cursorarrow.click.2", text: "Clicks, types, and scrolls to carry out your request.")
                    aboutRow(
                        icon: "checkmark.circle",
                        text: "Checks each step as it goes — and you can stop it any time."
                    )
                }
            }
        }
    }

    private func aboutRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.accentColor)
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)
            Text(LocalizedStringKey(text), bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Setup card (readiness + permissions)

    private var isAccessibilityGranted: Bool {
        permissionService.permissionStates[.accessibility] ?? false
    }

    private var setupCard: some View {
        SettingsSection(title: "Setup", icon: "checklist") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(
                        systemName: isAccessibilityGranted
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(isAccessibilityGranted ? theme.successColor : theme.warningColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            isAccessibilityGranted ? "Ready to use" : "Needs Accessibility permission",
                            bundle: .module
                        )
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                        bodyText(
                            isAccessibilityGranted
                                ? "Computer Use can control apps once you enable it for an agent."
                                : "Grant Accessibility below so agents can read and control apps."
                        )
                    }
                    Spacer()
                }

                VStack(spacing: 10) {
                    ComputerUsePermissionRow(
                        permission: .accessibility,
                        subtitleOverride: L(
                            "Lets agents read on-screen elements and click, type, and scroll for you."
                        )
                    )
                    ComputerUsePermissionRow(
                        permission: .screenRecording,
                        isOptional: true,
                        subtitleOverride: L(
                            "Only needed if an agent reads the screen visually (screenshots). The standard mode works without it."
                        )
                    )
                }
            }
        }
    }

    // MARK: - Enable card (per-agent steps)

    private var enableCard: some View {
        SettingsSection(title: "Turn it on", icon: "person.2.fill") {
            VStack(alignment: .leading, spacing: 12) {
                bodyText(
                    "Computer Use is off by default. You enable it per agent — and only custom agents can use it (the Default agent can't)."
                )

                VStack(alignment: .leading, spacing: 10) {
                    stepRow(number: 1, text: "Open the Agents tab and select a custom agent.")
                    stepRow(number: 2, text: "Go to Features and turn on Computer Use.")
                    stepRow(
                        number: 3,
                        text: "Optionally set that agent's Autonomy ceiling to cap how far it can act."
                    )
                }
            }
        }
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.accentColor)
                .frame(width: 18, height: 18)
                .background(Circle().fill(theme.accentColor.opacity(0.12)))
            Text(LocalizedStringKey(text), bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Consent card (safety)

    private var consentCard: some View {
        SettingsSection(title: "Staying in control", icon: "hand.raised.fill") {
            VStack(alignment: .leading, spacing: 10) {
                consentRow(
                    icon: "checkmark.circle.fill",
                    color: theme.successColor,
                    text: L("Reading the screen never changes anything, so it always runs automatically.")
                )
                consentRow(
                    icon: "questionmark.circle.fill",
                    color: theme.warningColor,
                    text: L(
                        "Actions that change or send something pause for your approval, based on the autonomy level below."
                    )
                )
                consentRow(
                    icon: "stop.circle.fill",
                    color: theme.accentColor,
                    text: L("You can stop a run at any time from the activity feed in chat.")
                )
            }
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

    // MARK: - Screen context card

    private var screenContextCard: some View {
        SettingsSection(title: "Screen context", icon: "rectangle.on.rectangle.angled") {
            VStack(alignment: .leading, spacing: 14) {
                bodyText(
                    "Give the assistant ambient awareness of what you're working on. When on, Osaurus freezes a quick snapshot of your open windows and the field you're focused on at the start of each chat, and shares it as background context. It's built from on-screen text only — no screenshots — and is scrubbed by the Privacy Filter before it reaches a cloud model."
                )

                screenContextPerAgentNote

                ScreenContextPreview(
                    accessibilityHint: "Grant Accessibility above to preview what would be shared."
                )
            }
        }
    }

    /// Screen context is a per-agent option nested under Computer Use (on by
    /// default once Computer Use is enabled), not a global switch. This blends
    /// in as a quiet caption pointing to where it lives; the live preview below
    /// shows what any enabled agent would freeze and share.
    private var screenContextPerAgentNote: some View {
        hintText(
            "Turn this on per agent: open the agent's Subagents tab, enable Computer Use, and use the Share screen context option (on by default). Requires Accessibility."
        )
    }

    // MARK: - Autonomy card

    private var policyCard: some View {
        SettingsSection(title: "Autonomy", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 16) {
                bodyText(
                    "Choose how much an agent can do on its own. Per-app rules and each agent's own ceiling can only make this stricter — never less safe."
                )

                VStack(spacing: 8) {
                    ForEach(AutonomyPreset.allCases) { preset in
                        presetOptionRow(preset)
                    }
                }

                whatHappensSummary
            }
        }
    }

    private func presetOptionRow(_ preset: AutonomyPreset) -> some View {
        let isSelected = policy.globalPreset == preset
        return Button {
            policy.globalPreset = preset
            persist()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(isSelected ? theme.accentColor : theme.tertiaryText)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(preset.detail)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(
                cornerRadius: 10,
                fill: isSelected ? theme.accentColor.opacity(0.08) : theme.inputBackground,
                stroke: isSelected ? theme.accentColor.opacity(0.5) : theme.inputBorder,
                lineWidth: isSelected ? 1.5 : 1
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// A live, plain-language readout of what the selected global preset
    /// actually does for each effect class, so the abstract stance becomes
    /// concrete. Mirrors `AutonomyPreset.disposition(for:)` exactly.
    private var whatHappensSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What this means right now", bundle: .module)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)

            VStack(spacing: 8) {
                ForEach(EffectClass.allCases, id: \.self) { effect in
                    effectSummaryRow(effect)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(cornerRadius: 10, fill: theme.tertiaryBackground)
    }

    private func effectSummaryRow(_ effect: EffectClass) -> some View {
        let info = effectInfo(effect)
        let disposition = policy.globalPreset.disposition(for: effect)
        return HStack(spacing: 10) {
            Image(systemName: info.icon)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(info.title), bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(LocalizedStringKey(info.example), bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            dispositionPill(disposition)
        }
    }

    private func dispositionPill(_ disposition: AutonomyDisposition) -> some View {
        let color = dispositionColor(disposition)
        return Text(disposition.displayLabel)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 0.5))
    }

    private func dispositionColor(_ disposition: AutonomyDisposition) -> Color {
        switch disposition {
        case .allow: return theme.successColor
        case .confirm: return theme.warningColor
        case .deny: return theme.errorColor
        }
    }

    /// Icon + plain-language label + example for each effect class, shown in
    /// the "What this means right now" summary.
    private func effectInfo(_ effect: EffectClass) -> (icon: String, title: String, example: String) {
        switch effect {
        case .read:
            return ("eye", "Looking", "Reading and finding things on screen")
        case .navigate:
            return ("cursorarrow.click", "Navigating", "Clicking links, scrolling, switching apps")
        case .edit:
            return ("pencil", "Editing", "Typing and changing values")
        case .consequential:
            return ("exclamationmark.triangle", "Risky actions", "Sending, deleting, or purchasing")
        }
    }

    // MARK: - Advanced (collapsed)

    private var advancedCard: some View {
        SettingsSection(title: "Advanced", icon: "gearshape.2") {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 18) {
                    perAppSection
                    SettingsDivider()
                    allowlistSection
                    SettingsDivider()
                    cloudVisionSection
                    SettingsDivider()
                    ComputerUseDiagnosticsPanel(policy: policy)
                }
                .padding(.top, 16)
            } label: {
                HStack(spacing: 8) {
                    Text("Per-app rules, app allowlist, and cloud vision.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                    Spacer()
                }
                .contentShape(Rectangle())
                // The native DisclosureGroup only toggles on the caret; make the
                // whole label row toggle it too.
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAdvanced.toggle()
                    }
                }
            }
            .accentColor(theme.tertiaryText)
        }
    }

    private var perAppSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L("Per-app rules"))
            hintText(
                "Hold a specific app to a stricter stance than your default. A rule can only add caution, never remove it."
            )

            if sortedOverrideKeys.isEmpty {
                emptyHint("No rules yet — every app uses your default above.")
            } else {
                ForEach(sortedOverrideKeys, id: \.self) { appKey in
                    appRow(icon: "app.dashed", iconColor: theme.secondaryText, name: appKey) {
                        let current = policy.perApp[appKey] ?? .cautious
                        presetPickerMenu(
                            Binding(
                                get: { current },
                                set: {
                                    policy.perApp[appKey] = $0
                                    persist()
                                }
                            ),
                            // Per-app rules can only TIGHTEN (strictest-wins merge), so
                            // a looser preset would silently no-op. Only offer presets
                            // at least as strict as the global default (plus whatever's
                            // currently selected, so a pre-existing rule stays visible).
                            options: perAppPresetOptions(current: current)
                        )
                        removeButton(help: L("Remove rule")) { removeOverride(appKey) }
                    }
                }
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
            sectionTitle(L("App allowlist"))
            hintText(
                "Leave empty to allow Computer Use in any app. Add apps to restrict it to ONLY those — every other app is blocked before any action."
            )

            if (policy.allowlist ?? []).isEmpty {
                emptyHint("Empty — Computer Use is allowed in any app.")
            } else {
                ForEach(policy.allowlist ?? [], id: \.self) { app in
                    appRow(icon: "checkmark.shield", iconColor: theme.successColor, name: app) {
                        removeButton(help: L("Remove from allowlist")) { removeAllowlisted(app) }
                    }
                }
            }

            appAddRow(
                placeholder: L("App name to allow"),
                text: $newAllowlistApp,
                action: addAllowlisted
            )
        }
    }

    private var cloudVisionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L("Cloud vision"))
            hintText(
                "Perception stays on this Mac by default. If an agent uses a cloud model, you can let it send screenshots for the rare cases on-screen text isn't enough — but only after sensitive text is masked on-device first."
            )

            SettingsToggle(
                title: L("Allow masked screenshots to reach a cloud model"),
                description: "Off by default. Nothing is sent without this and on-device masking.",
                isOn: Binding(
                    get: { cloudVisionConsent.isPersistentlyGranted },
                    set: { cloudVisionConsent.setPersistent($0) }
                )
            )

            // Redaction mode: mask everything (default, safest) vs. mask only
            // detected PII (less strict — leaves non-sensitive text readable).
            SettingsToggle(
                title: L("Mask only detected sensitive text"),
                description:
                    "Off (recommended): mask ALL on-screen text before sending. On: send a screenshot where only detected sensitive text (names, emails, numbers, secrets) is masked — other text stays readable to the model.",
                isOn: Binding(
                    get: { cloudVisionConsent.masksOnlyDetectedPII },
                    set: { cloudVisionConsent.setMasksOnlyDetectedPII($0) }
                )
            )

            hintText(
                "Masking runs on-device using OCR + the Privacy Filter (your configured rules plus an on-device model for names/addresses/dates/secrets). Detection isn't perfect — it can miss text OCR can't read or the model doesn't recognize — so \"mask only sensitive text\" trades some privacy for the model seeing more context. Screenshots also require Screen Recording permission; without it the agent stays on accessibility text only."
            )
        }
    }

    // MARK: - Advanced row helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(theme.primaryText)
    }

    private func emptyHint(_ text: String) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(cornerRadius: 8, fill: theme.inputBackground.opacity(0.5))
    }

    @ViewBuilder
    private func appRow<Trailing: View>(
        icon: String,
        iconColor: Color,
        name: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(iconColor)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .surface(cornerRadius: 8, fill: theme.inputBackground, stroke: theme.inputBorder)
    }

    private func removeButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 12))
                .foregroundColor(theme.errorColor)
        }
        .buttonStyle(PlainButtonStyle())
        .help(Text(help))
    }

    @ViewBuilder
    private func presetPickerMenu(
        _ selection: Binding<AutonomyPreset>,
        options: [AutonomyPreset] = AutonomyPreset.allCases
    ) -> some View {
        Menu {
            ForEach(options) { preset in
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
            .surface(cornerRadius: 6, fill: theme.tertiaryBackground, stroke: theme.inputBorder)
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
                .surface(cornerRadius: 6, fill: theme.inputBackground, stroke: theme.inputBorder)
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
                .surface(cornerRadius: 6, fill: theme.tertiaryBackground, stroke: theme.inputBorder)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    // MARK: - Policy mutations

    private var sortedOverrideKeys: [String] {
        policy.perApp.keys.sorted()
    }

    /// Presets a per-app rule may pick: those at least as strict as the global
    /// default on every effect (a looser one would silently no-op under the
    /// strictest-wins merge), plus the currently selected value so an existing
    /// rule never vanishes from its own menu.
    private func perAppPresetOptions(current: AutonomyPreset) -> [AutonomyPreset] {
        let global = policy.globalPreset
        let effects: [EffectClass] = [.navigate, .edit, .consequential]
        return AutonomyPreset.allCases.filter { preset in
            if preset == current { return true }
            return effects.allSatisfy {
                preset.disposition(for: $0) >= global.disposition(for: $0)
            }
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

    // MARK: - Card shell

    /// Standard panel paragraph: 12pt secondary text that wraps freely.
    private func bodyText(_ text: String) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Smaller 11pt tertiary helper/caption text.
    private func hintText(_ text: String) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Compact permission row

/// A compact status + action row for a single system permission. Lighter
/// than `PermissionsView`'s row (no diagnostic test button) since this
/// panel only needs to show grant status and route to System Settings.
/// `isOptional` softens the unmet state (a neutral "Optional" tag instead of
/// an alarming "Not Granted"), and `subtitleOverride` lets the caller supply
/// Computer-Use-specific copy in place of the generic plugin description.
private struct ComputerUsePermissionRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared
    let permission: SystemPermission
    var isOptional: Bool = false
    var subtitleOverride: String? = nil

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var isGranted: Bool {
        permissionService.permissionStates[permission] ?? false
    }

    private var statusText: String {
        if isGranted { return L("Granted") }
        return isOptional ? L("Optional") : L("Not Granted")
    }

    private var statusColor: Color {
        if isGranted { return theme.successColor }
        return isOptional ? theme.tertiaryText : theme.warningColor
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: permission.systemIconName)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(isGranted ? theme.successColor : theme.secondaryText)
                .frame(width: 40, height: 40)
                .surface(
                    cornerRadius: 10,
                    fill: isGranted ? theme.successColor.opacity(0.12) : theme.tertiaryBackground
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(permission.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)

                    Text(statusText)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(statusColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(statusColor.opacity(0.1)))
                }
                Text(subtitleOverride ?? permission.description)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
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
        .surface(
            cornerRadius: 12,
            fill: theme.inputBackground,
            stroke: isGranted ? theme.successColor.opacity(0.3) : theme.inputBorder
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
        .surface(
            cornerRadius: 6,
            fill: filled ? theme.accentColor : theme.tertiaryBackground,
            stroke: filled ? .clear : theme.inputBorder
        )
    }
}

// MARK: - Styling helpers

private extension View {
    /// The panel's standard filled-and-bordered rounded surface, applied as a
    /// background. A `.clear` stroke (the default) yields a fill-only surface.
    func surface(
        cornerRadius: CGFloat,
        fill: Color,
        stroke: Color = .clear,
        lineWidth: CGFloat = 1
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .stroke(stroke, lineWidth: lineWidth)
                )
        )
    }
}
