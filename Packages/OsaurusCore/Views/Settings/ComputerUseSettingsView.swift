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
//

import SwiftUI

struct ComputerUseSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared
    @ObservedObject private var cloudVisionConsent = CloudVisionConsent.shared
    @ObservedObject private var screenContext = ScreenContextSettings.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false

    /// Live screen-context preview state for the Screen context card. The
    /// snapshot is captured on demand (Refresh) so the user can see exactly
    /// what a new conversation would freeze and share.
    @State private var screenPreview: ScreenContextSnapshot?
    @State private var isLoadingScreenPreview = false
    /// Number of PII spans the Privacy Filter would mask in the preview, when
    /// the filter is enabled and its model is loaded. nil = not computed.
    @State private var screenMaskedCount: Int?

    /// The editable autonomy policy, loaded from `ComputerUsePolicyStore` on
    /// appear and persisted on every change.
    @State private var policy: AutonomyPolicy = .defaultPolicy
    @State private var newOverrideApp: String = ""
    @State private var newAllowlistApp: String = ""

    /// Power-user controls stay collapsed by default to keep the panel
    /// approachable for a first read.
    @State private var showAdvanced = false

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    aboutCard
                    setupCard
                    enableCard
                    consentCard
                    screenContextCard
                    policyCard
                    advancedCard
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
            if screenContext.injectionEnabled, isAccessibilityGranted {
                refreshScreenPreview()
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

    // MARK: - About card

    private var aboutCard: some View {
        infoCard(icon: "cursorarrow.rays", title: L("What it is")) {
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
        infoCard(icon: "checklist", title: L("Setup")) {
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
        infoCard(icon: "person.2.fill", title: L("Turn it on")) {
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
        infoCard(icon: "hand.raised.fill", title: L("Staying in control")) {
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
        infoCard(icon: "rectangle.on.rectangle.angled", title: L("Screen context")) {
            VStack(alignment: .leading, spacing: 14) {
                bodyText(
                    "Give the assistant ambient awareness of what you're working on. When on, Osaurus freezes a quick snapshot of your open windows and the field you're focused on at the start of each chat, and shares it as background context. It's built from on-screen text only — no screenshots — and is scrubbed by the Privacy Filter before it reaches a cloud model."
                )

                screenContextToggleRow

                if screenContext.injectionEnabled {
                    screenPreviewSection
                }
            }
        }
    }

    private var screenContextToggleRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Share screen context with chat"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                hintText(
                    "Off by default. Requires Accessibility. Frozen when each conversation starts."
                )
            }
            Spacer(minLength: 12)
            Toggle(
                "",
                isOn: Binding(
                    get: { screenContext.injectionEnabled },
                    set: { setScreenContextEnabled($0) }
                )
            )
            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
            .labelsHidden()
        }
        .padding(12)
        .surface(cornerRadius: 10, fill: theme.inputBackground, stroke: theme.inputBorder)
    }

    @ViewBuilder
    private var screenPreviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle(L("Preview"))
                Spacer()
                Button(action: { refreshScreenPreview() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                        Text(L("Refresh"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(theme.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .surface(cornerRadius: 6, fill: theme.tertiaryBackground, stroke: theme.inputBorder)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!isAccessibilityGranted || isLoadingScreenPreview)
            }

            if !isAccessibilityGranted {
                hintText("Grant Accessibility above to preview what would be shared.")
            } else if isLoadingScreenPreview {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    hintText("Reading the screen…")
                }
            } else if let preview = screenPreview {
                let text = preview.render()
                if text.isEmpty {
                    hintText("Nothing shareable detected on screen right now.")
                } else {
                    ScrollView {
                        Text(text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.secondaryText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                    .frame(maxHeight: 220)
                    .surface(cornerRadius: 8, fill: theme.inputBackground, stroke: theme.inputBorder)

                    privacyNote
                }
            } else {
                hintText("Tap Refresh to see what would be shared.")
            }
        }
    }

    @ViewBuilder
    private var privacyNote: some View {
        if PrivacyFilterStore.snapshot().enabled {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundColor(theme.successColor)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("The Privacy Filter scrubs this before it reaches a cloud model."))
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let count = screenMaskedCount, count > 0 {
                        Text(maskedCountText(count))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.warningColor)
                    }
                }
            }
        } else {
            hintText(
                "Local models receive this as-is. Turn on the Privacy Filter to scrub it before cloud sends."
            )
        }
    }

    private func maskedCountText(_ count: Int) -> String {
        count == 1
            ? L("~1 item would be masked before cloud send.")
            : String(format: L("~%d items would be masked before cloud send."), count)
    }

    private func setScreenContextEnabled(_ enabled: Bool) {
        screenContext.setEnabled(enabled)
        if enabled {
            refreshScreenPreview()
        } else {
            screenPreview = nil
            screenMaskedCount = nil
        }
    }

    private func refreshScreenPreview() {
        guard isAccessibilityGranted else {
            screenPreview = nil
            screenMaskedCount = nil
            return
        }
        isLoadingScreenPreview = true
        screenMaskedCount = nil
        Task { @MainActor in
            let snapshot = await ScreenContextDistiller.captureForChat()
            screenPreview = snapshot
            isLoadingScreenPreview = false
            await computeMaskedCount(for: snapshot.render())
        }
    }

    /// Best-effort count of spans the Privacy Filter would mask, shown so the
    /// user can gauge exposure. Only runs when the filter is enabled and its
    /// on-device model is already loaded — never blocks the preview on a model
    /// load.
    private func computeMaskedCount(for text: String) async {
        let config = PrivacyFilterStore.snapshot()
        guard config.enabled, !text.isEmpty, PrivacyFilterEngine.shared.isLoaded else {
            screenMaskedCount = nil
            return
        }
        let map = RedactionMap(conversationID: UUID())
        let detected = try? await PrivacyFilterEngine.shared.detect(
            in: text,
            map: map,
            skipCodeBlocks: config.skipCodeBlocks
        )
        screenMaskedCount = detected?.count
    }

    // MARK: - Autonomy card

    private var policyCard: some View {
        infoCard(icon: "slider.horizontal.3", title: L("Autonomy")) {
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
        card {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 18) {
                    perAppSection
                    Divider().background(theme.cardBorder)
                    allowlistSection
                    Divider().background(theme.cardBorder)
                    cloudVisionSection
                }
                .padding(.top, 16)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape.2")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(theme.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Advanced", bundle: .module)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text("Per-app rules, app allowlist, and cloud vision.", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
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
                        presetPickerMenu(
                            Binding(
                                get: { policy.perApp[appKey] ?? .cautious },
                                set: {
                                    policy.perApp[appKey] = $0
                                    persist()
                                }
                            )
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

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Allow masked screenshots to reach a cloud model"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    hintText("Off by default. Nothing is sent without this and on-device masking.")
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
            .padding(12)
            .surface(cornerRadius: 10, fill: theme.inputBackground, stroke: theme.inputBorder)
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

    /// The shared card container: 16pt padding inside a 12pt rounded surface.
    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(cornerRadius: 12, fill: theme.cardBackground, stroke: theme.cardBorder)
    }

    /// A titled card with an accent icon header, used by every info section.
    @ViewBuilder
    private func infoCard<Content: View>(
        icon: String,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        card {
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
        }
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
