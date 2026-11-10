//
//  ComputerUseSettingsView.swift
//  OsaurusCore — Computer Use
//
//  Capabilities → Computer & Browser Use. The overview reads top-down for a
//  first-time user: what the feature is, whether it's set up (permissions),
//  and how to turn it on per agent. Autonomy (the safety model, the stance
//  picker and, under Advanced, per-app rules / allowlist / cloud vision),
//  Screen Context and AppleScript open as drill-ins; Browser is a child tab.
//

import SwiftUI

// MARK: - Computer Use Items

/// Drill-in pages of Computer & Browser Use. Raw values are stable deep-link
/// ids (`computerUseSubTabRequest`). `setup` lands on the overview (where
/// setup now lives); `models` forwards to Local Models → AppleScript.
enum ComputerUseTab: String, CaseIterable, SettingsDrillInItem {
    case setup = "Setup"
    case autonomy = "Autonomy"
    case screenContext = "Screen Context"
    case appleScript = "AppleScript"
    case models = "Models"

    var id: String { rawValue }

    static let drillInItems: [ComputerUseTab] = [.autonomy, .screenContext, .appleScript]

    var title: String {
        switch self {
        case .setup: return L("Setup")
        case .autonomy: return L("Autonomy")
        case .screenContext: return L("Screen Context")
        case .appleScript: return L("AppleScript")
        case .models: return L("AppleScript Models")
        }
    }

    var icon: String {
        switch self {
        case .setup: return "checklist"
        case .autonomy: return "slider.horizontal.3"
        case .screenContext: return "rectangle.on.rectangle.angled"
        case .appleScript: return "applescript"
        case .models: return "arrow.down.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .setup: return ""
        case .autonomy: return L("How much an agent may do on its own; per-app rules, allowlist and cloud vision.")
        case .screenContext: return L("Share a text snapshot of your open windows at the start of each chat.")
        case .appleScript: return L("Automation permission and how generated scripts are gated.")
        case .models: return L("Download on-device AppleScript models.")
        }
    }
}

struct ComputerUseSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared
    @ObservedObject private var cloudVisionConsent = CloudVisionConsent.shared
    @ObservedObject private var managementState = ManagementStateManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    /// The editable autonomy policy, loaded from `ComputerUsePolicyStore` on
    /// appear and persisted on every change.
    @State private var policy: AutonomyPolicy = .defaultPolicy
    @State private var newOverrideApp: String = ""
    @State private var newAllowlistApp: String = ""

    /// Power-user controls stay collapsed by default to keep the panel
    /// approachable for a first read.
    @State private var showAdvanced = false

    @State private var selection: ComputerUseTab?
    /// Installed curated AppleScript model count, for the models row badge.
    /// Refreshed on appear and whenever local models change.
    @State private var appleScriptInstalledCount = 0

    var body: some View {
        SettingsDrillInHost(rootTitle: L("Computer & Browser Use"), selection: $selection) {
            overview
        } detail: { item in
            detail(item)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.surface.canvas)
        .environment(\.theme, themeManager.currentTheme)
        .task { await refreshAppleScriptInstalledCount() }
        .onReceive(NotificationCenter.default.publisher(for: .localModelsChanged)) { _ in
            Task { await refreshAppleScriptInstalledCount() }
        }
        .onChange(of: managementState.computerUseSubTabRequest) { _, _ in
            applySubTabRequestIfNeeded()
        }
        .onAppear {
            applySubTabRequestIfNeeded()
            policy = ComputerUsePolicyStore.load()
            permissionService.startPeriodicRefresh(interval: 2.0)
        }
        .onDisappear {
            permissionService.stopPeriodicRefresh()
        }
    }

    private func applySubTabRequestIfNeeded() {
        guard let requested = managementState.computerUseSubTabRequest else { return }
        managementState.computerUseSubTabRequest = nil
        switch ComputerUseTab(rawValue: requested) {
        case .setup: selection = nil
        case .models: managementState.openLocalModels(kind: .appleScript)
        case let tab?: selection = tab
        case nil: break
        }
    }

    // MARK: - Overview

    private var overview: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Computer & Browser Use",
                subtitle: "Let agents operate macOS apps and the web on your behalf",
                onRefresh: { permissionService.refreshAllPermissions() },
                refreshHelp: "Refresh permission status"
            )
        } content: {
            aboutCard
            setupCard
            enableCard
                .settingsLandingAnchor("computerUse.enable")
            SettingsSection(title: "More Settings") {
                SettingsDrillInRows(items: ComputerUseTab.drillInItems) { selection = $0 }
                ManagementChildLinkRows(parent: .computerUse)
                SettingsNavigationRow(
                    icon: ComputerUseTab.models.icon,
                    title: ComputerUseTab.models.title,
                    subtitle: ComputerUseTab.models.subtitle,
                    badge: appleScriptInstalledCount,
                    anchorId: "computerUse.models"
                ) {
                    managementState.openLocalModels(kind: .appleScript)
                }
            }
        }
    }

    @ViewBuilder
    private func detail(_ item: ComputerUseTab) -> some View {
        switch item {
        case .appleScript:
            VStack(spacing: 0) {
                SettingsPageHeader(title: item.title, subtitle: item.subtitle)
                AppleScriptAutomationView()
            }
        default:
            SettingsPage {
                SettingsPageHeader(title: item.title, subtitle: item.subtitle)
            } content: {
                switch item {
                case .screenContext:
                    screenContextCard
                default:
                    consentCard
                    policyCard
                    advancedCard
                }
            }
        }
    }

    private func refreshAppleScriptInstalledCount() async {
        appleScriptInstalledCount = AppleScriptModelCatalog.installedModels().count
    }

    // MARK: - About card

    private var aboutCard: some View {
        SettingsSection(title: "What It Is") {
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
                .glyphSize(12, weight: .medium)
                .foregroundColor(theme.text.link)
                .frame(width: 18, alignment: .center)
                .padding(.top, theme.space.s2)
            Text(LocalizedStringKey(text), bundle: .module)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Setup card (readiness + permissions)

    private var isAccessibilityGranted: Bool {
        permissionService.permissionStates[.accessibility] ?? false
    }

    private var setupCard: some View {
        SettingsSection(
            title: "Setup",
            subtitle: isAccessibilityGranted
                ? "Computer Use can control apps once you enable it for an agent."
                : "Grant Accessibility below so agents can read and control apps."
        ) {
            StatusChip(
                isAccessibilityGranted ? L("Ready to use") : L("Needs Accessibility permission"),
                tone: isAccessibilityGranted ? .success : .warning,
                icon: isAccessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
        } content: {
            SettingsPermissionRow(
                permission: .accessibility,
                description: L("Lets agents read on-screen elements and click, type, and scroll for you.")
            )
            SettingsPermissionRow(
                permission: .screenRecording,
                isOptional: true,
                description: L(
                    "Only needed if an agent reads the screen visually (screenshots). The standard mode works without it."
                )
            )
        }
    }

    // MARK: - Enable card (per-agent steps)

    private var enableCard: some View {
        SettingsSection(title: "Turn It On") {
            VStack(alignment: .leading, spacing: 12) {
                bodyText(
                    "Computer Use is off by default. You enable it per agent — and only custom agents can use it (the Default agent can't)."
                )

                VStack(alignment: .leading, spacing: 10) {
                    stepRow(number: 1, text: "Open the Agents tab and select a custom agent.")
                    stepRow(number: 2, text: "Open Abilities → Subagents and turn on Computer Use.")
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
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.link)
                .frame(width: 18, height: 18)
                .background(Circle().fill(theme.status.info.background))
            Text(LocalizedStringKey(text), bundle: .module)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Consent card (safety)

    private var consentCard: some View {
        SettingsSection(title: "Staying in Control") {
            VStack(alignment: .leading, spacing: 10) {
                consentRow(
                    icon: "checkmark.circle.fill",
                    color: theme.status.success.foreground,
                    text: L("Reading the screen never changes anything, so it always runs automatically.")
                )
                consentRow(
                    icon: "questionmark.circle.fill",
                    color: theme.status.warning.foreground,
                    text: L(
                        "Actions that change or send something pause for your approval, based on the autonomy level below."
                    )
                )
                consentRow(
                    icon: "stop.circle.fill",
                    color: theme.action.primary.default.background,
                    text: L("You can stop a run at any time from the activity feed in chat.")
                )
            }
        }
    }

    private func consentRow(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .glyphSize(12)
                .foregroundColor(color)
                .padding(.top, theme.space.s2)
            Text(text)
                .font(SettingsFont.caption)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Screen context card

    private var screenContextCard: some View {
        SettingsSection(title: "Screen Context") {
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
        SettingsSection(title: "Autonomy") {
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
                    .glyphSize(16)
                    .foregroundColor(isSelected ? theme.text.link : theme.text.tertiary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.displayLabel)
                        .font(SettingsFont.sectionTitle)
                        .foregroundColor(theme.text.primary)
                    Text(preset.detail)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }
            .padding(theme.space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(isSelected ? .selected : .control)
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
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)

            VStack(spacing: 8) {
                ForEach(EffectClass.allCases, id: \.self) { effect in
                    effectSummaryRow(effect)
                }
            }
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.inset)
    }

    private func effectSummaryRow(_ effect: EffectClass) -> some View {
        let info = effectInfo(effect)
        let disposition = policy.globalPreset.disposition(for: effect)
        return HStack(spacing: 10) {
            Image(systemName: info.icon)
                .glyphSize(12)
                .foregroundColor(theme.text.secondary)
                .frame(width: 18, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(info.title), bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Text(LocalizedStringKey(info.example), bundle: .module)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            dispositionPill(disposition)
        }
    }

    private func dispositionPill(_ disposition: AutonomyDisposition) -> some View {
        let color = dispositionColor(disposition)
        return StatusChip(disposition.displayLabel, tint: color)
    }

    private func dispositionColor(_ disposition: AutonomyDisposition) -> Color {
        switch disposition {
        case .allow: return theme.status.success.foreground
        case .confirm: return theme.status.warning.foreground
        case .deny: return theme.status.error.foreground
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
        SettingsSection(title: "Advanced") {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 18) {
                    perAppSection
                    allowlistSection
                    cloudVisionSection
                    ComputerUseDiagnosticsPanel(policy: policy)
                }
                .padding(.top, theme.space.s16)
            } label: {
                HStack(spacing: 8) {
                    Text("Per-app rules, app allowlist, and cloud vision.", bundle: .module)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                    Spacer()
                }
                .contentShape(Rectangle())
                // The native DisclosureGroup only toggles on the caret; make the
                // whole label row toggle it too.
                .onTapGesture {
                    withAnimation(theme.motion.quick) {
                        showAdvanced.toggle()
                    }
                }
            }
            .tint(theme.text.tertiary)
        }
    }

    private var perAppSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(L("Per-app rules"))
            hintText(
                "Hold a specific app to a stricter stance than your default. A rule can only add caution, never remove it."
            )

            if sortedOverrideKeys.isEmpty {
                SettingsEmptyState(inline: "app.dashed", title: "No rules yet", hint: "Every app uses your default above.")
            } else {
                ForEach(sortedOverrideKeys, id: \.self) { appKey in
                    appRow(icon: "app.dashed", iconColor: theme.text.secondary, name: appKey) {
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
                SettingsEmptyState(
                    inline: "checkmark.shield",
                    title: "No apps on the allowlist",
                    hint: "Computer Use is allowed in any app."
                )
            } else {
                ForEach(policy.allowlist ?? [], id: \.self) { app in
                    appRow(icon: "checkmark.shield", iconColor: theme.status.success.foreground, name: app) {
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
                title: "Allow Masked Screenshots to Reach a Cloud Model",
                description: "Off by default. Nothing is sent without this and on-device masking.",
                isOn: Binding(
                    get: { cloudVisionConsent.isPersistentlyGranted },
                    set: { cloudVisionConsent.setPersistent($0) }
                )
            )

            // Redaction mode: mask everything (default, safest) vs. mask only
            // detected PII (less strict — leaves non-sensitive text readable).
            SettingsToggle(
                title: "Mask Only Detected Sensitive Text",
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
            .font(SettingsFont.compactLabel)
            .foregroundColor(theme.text.primary)
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
                .glyphSize(12)
                .foregroundColor(iconColor)
            Text(name)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s8)
        .settingsChrome(.control)
    }

    private func removeButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "trash")
                .glyphSize(12)
                .foregroundColor(theme.status.error.foreground)
        }
        .buttonStyle(PlainButtonStyle())
        .help(Text(help))
    }

    @ViewBuilder
    private func presetPickerMenu(
        _ selection: Binding<AutonomyPreset>,
        options: [AutonomyPreset] = AutonomyPreset.allCases
    ) -> some View {
        SettingsMenuPicker(selection: selection) {
            ForEach(options) { preset in
                Text(preset.displayLabel).tag(preset)
            }
        }
    }

    @ViewBuilder
    private func appAddRow(placeholder: String, text: Binding<String>, action: @escaping () -> Void)
        -> some View
    {
        HStack(spacing: 8) {
            SettingsTextField(placeholder: placeholder, text: text, onSubmit: action)
            Button(action: action) {
                Label(L("Add"), systemImage: "plus")
            }
            .assignedSettingsButtonStyle(.secondary, size: .compact)
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
            .font(SettingsFont.caption)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Smaller 11pt tertiary helper/caption text.
    private func hintText(_ text: String) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
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
