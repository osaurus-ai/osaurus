//
//  IdentityView.swift
//  osaurus
//
//  Osaurus Identity management UI: master address, agent addresses,
//  device status, setup flow, and recovery code handling.
//

import AppKit
import LocalAuthentication
import SwiftUI

// MARK: - Identity View

struct IdentityView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var osaurusID = OsaurusIDService.shared
    @EnvironmentObject private var server: ServerController
    private var theme: any ThemeProtocol { themeManager.currentTheme }

    @State private var phase: IdentityPhase = .checking
    @State private var drift: IdentityDrift?

    /// Non-nil presents `RecoverFromMnemonicSheet` in the given mode
    /// (drift repair, fresh restore, or replace-existing).
    @State private var restoreSheetMode: RecoverFromMnemonicMode?
    @State private var showRepairConfirm = false
    @State private var showResetConfirm = false
    @State private var showRecoveryPhraseSheet = false
    @State private var recoveryPhraseWords: [String]?
    @State private var recoveryPhraseError: String?
    @State private var isLoadingRecoveryPhrase = false
    @State private var lastActionResult: ActionResult?

    /// Result of the most recent recover / repair / reset action, surfaced in
    /// the inline banner above the sections. `nil` hides the banner.
    private struct ActionResult {
        let message: String
        let isError: Bool
    }

    var body: some View {
        SettingsPage {
            headerView
        } content: {
            phaseContent
        }
        .onAppear { checkIdentityStatus() }
        .sheet(
            isPresented: Binding(
                get: { restoreSheetMode != nil },
                set: { if !$0 { restoreSheetMode = nil } }
            )
        ) {
            RecoverFromMnemonicSheet(
                mode: restoreSheetMode ?? .freshRestore,
                onRecovered: handleRecovered,
                onCancel: { restoreSheetMode = nil }
            )
            .environment(\.theme, theme)
        }
        .sheet(isPresented: $showRecoveryPhraseSheet) {
            RecoveryPhraseSheet(
                words: recoveryPhraseWords ?? [],
                error: recoveryPhraseError,
                onClose: closeRecoveryPhraseSheet
            )
            .environment(\.theme, theme)
        }
        .alert(
            Text("Repair Identity?", bundle: .module),
            isPresented: $showRepairConfirm,
            actions: {
                Button(localized: "Repair", role: .destructive) { repair() }
                Button(localized: "Cancel", role: .cancel) {}
            },
            message: { Text(repairConfirmMessage, bundle: .module) }
        )
        .alert(
            Text("Reset Identity?", bundle: .module),
            isPresented: $showResetConfirm,
            actions: {
                Button(localized: "Reset", role: .destructive) { resetIdentity() }
                Button(localized: "Cancel", role: .cancel) {}
            },
            message: {
                Text(
                    "This deletes your signature, every agent's derived address, and every access key. Onboarding will start over. The backup in your iCloud Keychain will also be removed.",
                    bundle: .module
                )
            }
        )
    }

    // MARK: - Phase content

    @ViewBuilder
    private var phaseContent: some View {
        switch phase {
        case .checking:
            SettingsEmptyState(loading: "Loading identity...")
        case .noIdentity:
            IdentitySetupCard(
                onCreated: handleIdentityCreated,
                onRestore: { restoreSheetMode = .freshRestore },
                onCheckAgain: checkIdentityStatus
            )
            .settingsLandingAnchor("identity.keys")
            ManagementChildLinks(parent: .identity)
        case .ready(let osaurusId, _):
            readyContent(osaurusId: osaurusId)
        }
    }

    @ViewBuilder
    private func readyContent(osaurusId: OsaurusID) -> some View {
        if let drift, drift.hasDrift {
            IdentityDriftBanner(
                drift: drift,
                onRecover: { restoreSheetMode = .driftRepair(drift) },
                onRepair: { showRepairConfirm = true },
                onReset: { showResetConfirm = true }
            )
        }

        if let lastActionResult {
            actionResultBanner(lastActionResult)
        }

        // The human-facing identity first; the cryptographic material below.
        OsaurusIDSection()
            .settingsLandingAnchor("identity.osaurusId")
        SignInWithOsaurusSection()
            .settingsLandingAnchor("identity.signInWithOsaurus")

        ManagementChildLinks(parent: .identity)

        MasterAddressSection(
            osaurusId: osaurusId,
            isLoadingPhrase: isLoadingRecoveryPhrase,
            onViewRecoveryPhrase: viewRecoveryPhrase
        )
        .settingsLandingAnchor("identity.keys")
        AgentAddressesSection(
            masterAddress: osaurusId,
            mismatchedAgentIds: Set((drift?.mismatchedAgents ?? []).map(\.id)),
            onChange: { runRefresh() }
        )
        DevicesLinkSection()
        DangerZoneSection(
            onRestore: { restoreSheetMode = .replaceExisting(current: osaurusId) },
            onReset: { showResetConfirm = true }
        )
    }

    // MARK: - Header

    private var headerView: some View {
        SettingsPageHeader(title: "Osaurus ID", subtitle: subtitleText)
    }

    private var subtitleText: String {
        switch phase {
        case .checking:
            return "Loading identity..."
        case .noIdentity:
            return "Set up your Osaurus Identity"
        case .ready:
            if drift?.hasDrift == true { return "Identity drift detected" }
            if let handle = osaurusID.claimedHandle {
                return "@\(handle) · Your identity is active"
            }
            return "Your identity is active"
        }
    }

    private var repairConfirmMessage: LocalizedStringKey {
        let agents = drift?.mismatchedAgents.count ?? 0
        let keys = drift?.staleAccessKeys.count ?? 0
        switch (agents == 1, keys == 1) {
        case (true, true):
            return "Repair will derive a fresh address for 1 agent and revoke 1 stale access key under the current master. Existing pairings and clients holding that key will stop working until it's re-issued."
        case (true, false):
            return "Repair will derive a fresh address for 1 agent and revoke \(keys) stale access keys under the current master. Existing pairings and clients holding those keys will stop working until they're re-issued."
        case (false, true):
            return "Repair will derive fresh addresses for \(agents) agents and revoke 1 stale access key under the current master. Existing pairings and clients holding that key will stop working until it's re-issued."
        case (false, false):
            return "Repair will derive fresh addresses for \(agents) agents and revoke \(keys) stale access keys under the current master. Existing pairings and clients holding those keys will stop working until they're re-issued."
        }
    }

    private func actionResultBanner(_ result: ActionResult) -> some View {
        InlineBanner(
            kind: result.isError ? .error : .success,
            title: result.message,
            icon: result.isError ? "exclamationmark.triangle.fill" : "checkmark.shield.fill",
            onDismiss: { lastActionResult = nil }
        )
    }

    // MARK: - State Machine

    private func checkIdentityStatus() {
        if OsaurusIdentity.exists() {
            loadExistingIdentity()
        } else {
            phase = .noIdentity
            drift = nil
        }
    }

    private func loadExistingIdentity() {
        let agents = agentManager.agents
        Task { @MainActor in
            // The device and master key reads block on securityd XPC + decrypt,
            // which can take seconds on a slow or legacy keychain, so the load
            // runs off the main actor and only the resulting phase is published.
            let (newPhase, newDrift, repairedScopes): (IdentityPhase, IdentityDrift?, Int) = await Task.detached(
                priority: .userInitiated
            ) {
                do {
                    // A master that synced here via iCloud Keychain has no
                    // device key yet; attest on first sight instead of
                    // reporting "no identity" for an identity that exists.
                    let deviceId = try await OsaurusIdentity.ensureDeviceAttested()
                    let context = OsaurusIdentityContext.biometric()
                    var masterKeyData = try MasterKey.getPrivateKey(context: context)
                    defer { masterKeyData.zeroOut() }

                    let osaurusId = try deriveOsaurusId(from: masterKeyData)

                    let accessKeys = APIKeyManager.shared.listKeys()
                    var diagnosed = IdentityHealthCheck.diagnose(
                        masterKey: masterKeyData,
                        agents: agents,
                        accessKeys: accessKeys,
                        currentDeviceScope: deviceId
                    )
                    // A device scope dropped by an older build is restored
                    // in place — no re-mint, no revocation — then the
                    // diagnosis is re-run so the banner reflects real drift.
                    var repaired = 0
                    if !diagnosed.recoverableScopeAgents.isEmpty {
                        let recoverable = diagnosed.recoverableScopeAgents
                        let refreshedAgents: [Agent] = await MainActor.run {
                            repaired = AgentManager.shared.repairDeviceScope(for: recoverable, scope: deviceId)
                            return AgentManager.shared.agents
                        }
                        diagnosed = IdentityHealthCheck.diagnose(
                            masterKey: masterKeyData,
                            agents: refreshedAgents,
                            accessKeys: accessKeys,
                            currentDeviceScope: deviceId
                        )
                    }
                    return (.ready(osaurusId: osaurusId, deviceId: deviceId), diagnosed, repaired)
                } catch {
                    return (.noIdentity, nil, 0)
                }
            }.value

            phase = newPhase
            drift = newDrift
            if repairedScopes > 0 {
                lastActionResult = ActionResult(
                    message:
                        "Restored the device scope for \(repairedScopes) agent address(es) saved by an older version. No keys were changed.",
                    isError: false
                )
            }
        }
    }

    private func runRefresh() {
        APIKeyManager.shared.reload()
        agentManager.refresh()
        loadExistingIdentity()
    }

    private func handleIdentityCreated(_ info: IdentityInfo) {
        // The mnemonic is now stored in iCloud Keychain by
        // `OsaurusIdentity.setup()` itself, so there's nothing to gate the
        // user behind a write-it-down screen anymore. Drop straight into
        // the ready state — they can pull the phrase from "View recovery
        // phrase" whenever they want.
        phase = .ready(osaurusId: info.osaurusId, deviceId: info.deviceId)
        runRefresh()
    }

    // MARK: - Recover

    private func handleRecovered(_ result: OsaurusIdentity.RestoreResult) {
        restoreSheetMode = nil

        var parts = ["Identity \(result.osaurusId) restored from recovery phrase."]
        if result.rederivedAgentCount > 0 {
            parts.append("Re-derived addresses for \(result.rederivedAgentCount) agent(s).")
        }
        if result.revokedAccessKeyCount > 0 {
            parts.append("Revoked \(result.revokedAccessKeyCount) stale access key(s).")
        }
        var message = parts.joined(separator: " ")
        if !result.failures.isEmpty {
            message += "\nCompleted with errors:\n" + result.failures.joined(separator: "\n")
        }

        lastActionResult = ActionResult(message: message, isError: !result.failures.isEmpty)
        runRefresh()
        restartServerIfRunning()
    }

    // MARK: - Repair

    private func repair() {
        guard let drift else { return }

        var failures: [String] = []
        for agent in drift.mismatchedAgents {
            do {
                // Forget the stale derivation, then re-assign at a fresh index
                // off the current master.
                var cleared = agent
                cleared.agentIndex = nil
                cleared.agentDeviceScope = nil
                cleared.agentAddress = nil
                agentManager.update(cleared)
                if let refreshed = agentManager.agent(for: agent.id) {
                    try agentManager.assignAddress(to: refreshed)
                }
            } catch {
                failures.append("\(agent.name): \(error.localizedDescription)")
            }
        }

        for key in drift.staleAccessKeys where !key.revoked {
            do {
                try AccessKeyLifecycleService.shared.revokeAndRemove(id: key.id)
            } catch {
                failures.append("\(key.label): \(error.localizedDescription)")
            }
        }

        lastActionResult =
            failures.isEmpty
            ? ActionResult(
                message: "Repair complete. Re-derived agent addresses and revoked stale access keys.",
                isError: false
            )
            : ActionResult(
                message: "Repair completed with errors:\n" + failures.joined(separator: "\n"),
                isError: true
            )

        runRefresh()
        restartServerIfRunning()
    }

    // MARK: - Reset

    private func resetIdentity() {
        OsaurusIdentity.wipe()
        OnboardingService.shared.resetOnboarding()

        lastActionResult = ActionResult(
            message: "Identity reset. Re-open the app to start onboarding.",
            isError: false
        )
        phase = .noIdentity
        drift = nil

        restartServerIfRunning()
    }

    private func restartServerIfRunning() {
        guard server.isRunning else { return }
        Task { await server.restartServer() }
    }

    // MARK: - View recovery phrase

    /// Read the stored 24-word phrase out of iCloud Keychain and surface it
    /// in a sheet. Existing users who pre-date `MasterMnemonicStore` won't
    /// have an entry there yet, so on `errSecItemNotFound` we re-derive
    /// the phrase from the seed (one more biometric prompt) and write it
    /// through. Subsequent reads hit the store directly.
    private func viewRecoveryPhrase() {
        guard !isLoadingRecoveryPhrase else { return }
        isLoadingRecoveryPhrase = true
        recoveryPhraseWords = nil
        recoveryPhraseError = nil

        Task { @MainActor in
            // Same slow-keychain hazard as the identity load: the mnemonic and
            // seed reads block on securityd, so resolve the words off the main actor.
            let outcome: Result<[String], Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let context = OsaurusIdentityContext.biometric()
                    let words: [String]
                    if MasterMnemonicStore.exists() {
                        words = try MasterMnemonicStore.load(context: context)
                    } else {
                        // Backfill from the seed for legacy installs.
                        var seed = try MasterKey.getPrivateKey(context: context)
                        defer { seed.zeroOut() }
                        let derived = try MasterKeyMnemonic.mnemonic(forKey: seed)
                        try? MasterMnemonicStore.store(derived)
                        words = derived
                    }
                    return .success(words)
                } catch {
                    return .failure(error)
                }
            }.value

            switch outcome {
            case .success(let words):
                recoveryPhraseWords = words
            case .failure(let error):
                recoveryPhraseError = error.localizedDescription
            }
            isLoadingRecoveryPhrase = false
            showRecoveryPhraseSheet = true
        }
    }

    private func closeRecoveryPhraseSheet() {
        showRecoveryPhraseSheet = false
        recoveryPhraseWords = nil
        recoveryPhraseError = nil
    }
}

// MARK: - Identity Phase

private enum IdentityPhase {
    case checking
    case noIdentity
    case ready(osaurusId: OsaurusID, deviceId: String)
}

// MARK: - Drift Banner

private struct IdentityDriftBanner: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let drift: IdentityDrift
    let onRecover: () -> Void
    let onRepair: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(spacing: theme.space.s8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .glyphSize(14, weight: .semibold)
                    .foregroundColor(theme.status.error.foreground)
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text("Identity drift detected", bundle: .module)
                        .catalogTypography(.heading, theme: theme, fallback: SettingsFont.cardTitle)
                        .foregroundColor(theme.status.error.foreground)
                    Text(summary)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Text(
                "Your current Master Key no longer matches the addresses your agents and access keys were derived from. This usually means a Master Key was created on top of an existing one — for example, by a re-run of onboarding.",
                bundle: .module
            )
            .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: theme.space.s8) {
                SettingsButton(.primary, "Recover from phrase", icon: "arrow.uturn.backward", size: .compact) {
                    onRecover()
                }
                SettingsButton(.secondary, "Repair forward", icon: "wrench.and.screwdriver", size: .compact) {
                    onRepair()
                }
                SettingsButton(.destructive, "Reset identity", icon: "trash", size: .compact) {
                    onReset()
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, theme.space.s16).padding(.vertical, theme.space.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.status(.error))
    }

    private var summary: String {
        let agents = drift.mismatchedAgents.count
        let keys = drift.staleAccessKeys.count
        switch (agents, keys) {
        case (0, 0): return "Drift detected"
        case (1, 0): return "1 agent address no longer derives from this master."
        case (let a, 0): return "\(a) agent addresses no longer derive from this master."
        case (0, 1): return "1 access key signed by a previous master."
        case (0, let k): return "\(k) access keys signed by a previous master."
        case (1, 1):
            return "1 agent address and 1 access key reference a previous master."
        case (1, let k):
            return "1 agent address and \(k) access keys reference a previous master."
        case (let a, 1):
            return "\(a) agent addresses and 1 access key reference a previous master."
        case (let a, let k):
            return "\(a) agent addresses and \(k) access keys reference a previous master."
        }
    }
}

// MARK: - Danger Zone

private struct DangerZoneSection: View {
    let onRestore: () -> Void
    let onReset: () -> Void

    var body: some View {
        SettingsDestructiveZone {
            SettingsDestructiveRow(
                title: "Restore From Recovery Phrase",
                description:
                    "Replaces the identity on this Mac with one restored from a 24-word phrase. Agents get new addresses and existing access keys are revoked.",
                actionTitle: "Restore…",
                severity: .warning,
                action: onRestore
            )
            SettingsDestructiveRow(
                title: "Reset Identity",
                description:
                    "Wipes your signature, every agent address, and every access key, including the backup in your iCloud Keychain. Onboarding will start over.",
                actionTitle: "Reset…",
                action: onReset
            )
        }
    }
}

// MARK: - Biometric Context Helper

enum OsaurusIdentityContext {
    static func biometric() -> LAContext {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 300
        return context
    }
}

// MARK: - Setup Card

private struct IdentitySetupCard: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: any ThemeProtocol { themeManager.currentTheme }

    let onCreated: (IdentityInfo) -> Void
    /// Open the fresh-restore mnemonic sheet.
    let onRestore: () -> Void
    /// Re-probe Keychain — an identity synced from another device via iCloud
    /// Keychain may have arrived since this card was rendered.
    let onCheckAgain: () -> Void

    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: theme.settingsSectionGap) {
            Spacer().frame(height: 40)

            Image(systemName: "person.badge.key.fill")
                .glyphSize(48)
                .foregroundStyle(theme.text.link)

            VStack(spacing: theme.space.s8) {
                Text("Create Your Osaurus Identity", bundle: .module)
                    .catalogTypography(.heading, theme: theme, fallback: SettingsFont.pageTitle)
                    .foregroundColor(theme.text.primary)

                Text(
                    "Generate a cryptographic identity stored securely\nin your iCloud Keychain and Secure Enclave.",
                    bundle: .module
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.body)
                .foregroundColor(theme.text.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            }

            if let errorMessage {
                InlineBanner(kind: .error, title: errorMessage)
            }

            SettingsButton(.primary, "Generate Identity", icon: "key.fill", isLoading: isCreating, action: createIdentity)
                .disabled(isCreating)

            SettingsButton(.secondary, "Restore From Recovery Phrase", icon: "arrow.counterclockwise.circle", action: onRestore)
                .disabled(isCreating)

            VStack(spacing: theme.space.s4) {
                Text(
                    "Already using Osaurus on another device? With iCloud Keychain enabled on both, your identity restores here automatically — it can take a few minutes to sync.",
                    bundle: .module
                )
                .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

                SettingsButton(.tertiary, "Check Again", size: .compact, action: onCheckAgain)
            }

            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity)
        .settingsChrome(.card)
    }

    private func createIdentity() {
        isCreating = true
        errorMessage = nil

        Task {
            do {
                let info = try await OsaurusIdentity.setup()
                await MainActor.run {
                    isCreating = false
                    onCreated(info)
                }
            } catch {
                await MainActor.run {
                    isCreating = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Recovery Phrase Sheet

/// Modal that shows the 24-word backup phrase after a biometric-gated
/// fetch from `MasterMnemonicStore`. Renders the shared
/// `MasterMnemonicCard` (copy / save / print) when the load succeeded,
/// or a friendly error card otherwise.
private struct RecoveryPhraseSheet: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }

    let words: [String]
    let error: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s16) {
            HStack {
                VStack(alignment: .leading, spacing: theme.space.s2) {
                    Text("Your recovery phrase", bundle: .module)
                        .catalogTypography(.heading, theme: theme, fallback: SettingsFont.detailTitle)
                        .foregroundColor(theme.text.primary)
                    Text(
                        "Save it somewhere safe. Anyone with these words can recover your identity.",
                        bundle: .module
                    )
                    .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                    .foregroundColor(theme.text.secondary)
                }
                Spacer()
                SettingsIconButton("xmark", help: "Close", size: .compact, action: onClose)
            }

            if let error {
                errorCard(error)
            } else if !words.isEmpty {
                MasterMnemonicCard(words: words)
                    .environment(\.theme, theme)
            }

            HStack {
                Spacer()
                Button(action: onClose) {
                    Text("Done", bundle: .module)
                }
                .assignedSettingsButtonStyle(.primary)
            }
        }
        .padding(.horizontal, theme.settingsPageInset).padding(.vertical, theme.space.s24)
        .frame(width: 540)
        .background(theme.surface.canvas)
    }

    private func errorCard(_ message: String) -> some View {
        InlineBanner(kind: .error, title: L("Couldn't load your phrase"), caption: message)
    }
}

// MARK: - Master Address Section

private struct MasterAddressSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: any ThemeProtocol { themeManager.currentTheme }

    let osaurusId: OsaurusID
    let isLoadingPhrase: Bool
    let onViewRecoveryPhrase: () -> Void

    @State private var copied = false

    var body: some View {
        SettingsSection(
            title: "Master Address",
            subtitle:
                "The key your Osaurus ID, agents and sign-ins are built from. Your recovery phrase restores it on a new Mac, so keep the phrase somewhere safe."
        ) {
            HStack(spacing: theme.space.s8) {
                Text(osaurusId)
                    .catalogTypography(.code, theme: theme, fallback: SettingsFont.mono)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Spacer(minLength: theme.space.s12)

                SettingsButton(
                    .secondary,
                    "View recovery phrase",
                    icon: "key.viewfinder",
                    isLoading: isLoadingPhrase,
                    size: .compact,
                    action: onViewRecoveryPhrase
                )
                .disabled(isLoadingPhrase)

                SettingsButton(
                    .secondary,
                    copied ? "Copied" : "Copy",
                    icon: copied ? "checkmark" : "doc.on.doc",
                    size: .compact,
                    action: copyId
                )
            }

            SettingsRow(title: "Recovery", description: "") {
                StatusChip(L("Backed up in iCloud Keychain"), tone: .success, icon: "checkmark.shield.fill")
            }

            SettingsRow(title: "Status", description: "") {
                StatusChip(L("Active"), tone: .success, showsDot: true)
            }
        }
    }

    private func copyId() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(osaurusId, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }
}

// MARK: - Agent Addresses Section

private struct AgentAddressesSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @EnvironmentObject private var server: ServerController
    private var theme: any ThemeProtocol { themeManager.currentTheme }

    let masterAddress: OsaurusID
    let mismatchedAgentIds: Set<UUID>
    let onChange: () -> Void

    @State private var copiedAddress: OsaurusID?
    @State private var expandedAgentId: UUID?
    @State private var errorMessage: String?

    @State private var generatorAgent: Agent?
    @State private var generatorLabel: String = ""
    @State private var generatorExpiration: AccessKeyExpiration = .days90
    @State private var generatorError: String?
    @State private var generatorBusy: Bool = false
    @State private var lastGeneratedKey: String?

    private var customAgents: [Agent] {
        agentManager.agents.filter { !$0.isBuiltIn }
    }

    var body: some View {
        SettingsSection(title: "Agent Addresses") {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                if customAgents.isEmpty {
                    Text("No agents yet — create one in the Agents tab", bundle: .module)
                        .catalogTypography(.caption, theme: theme, fallback: SettingsFont.caption)
                        .foregroundColor(theme.text.tertiary)
                        .padding(.vertical, theme.space.s4)
                } else {
                    ForEach(customAgents) { agent in
                        if agent.agentAddress == nil {
                            unassignedRow(for: agent)
                        } else {
                            AgentKeyManagementRow(
                                agent: agent,
                                isMismatched: mismatchedAgentIds.contains(agent.id),
                                isExpanded: expandedAgentId == agent.id,
                                onToggleExpanded: { toggleExpanded(agent.id) },
                                onRotate: { rotateKey(for: agent) },
                                onRevoke: { revokeKey(for: agent) },
                                onGenerateAccessKey: { openGenerator(for: agent) },
                                onRevokeAccessKey: { id in revokeAccessKey(id) },
                                copiedAddress: copiedAddress,
                                onCopyAddress: copyAddress(_:),
                                accessKeys: accessKeys(for: agent)
                            )
                        }
                    }
                }

                if let lastGeneratedKey {
                    GeneratedAccessKeyBanner(
                        key: lastGeneratedKey,
                        onDismiss: { self.lastGeneratedKey = nil }
                    )
                }

                if let errorMessage {
                    Text(errorMessage)
                        .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                        .foregroundColor(theme.status.error.foreground)
                }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { generatorAgent != nil },
                set: { newValue in if !newValue { closeGenerator() } }
            )
        ) {
            if let agent = generatorAgent {
                AccessKeyGeneratorSheet(
                    theme: theme,
                    title: "Generate Access Key",
                    scopeCaption: LocalizedStringKey(
                        "Scoped to \(agent.name) (\(agent.agentAddress ?? "?"))"
                    ),
                    label: $generatorLabel,
                    expiration: $generatorExpiration,
                    isGenerating: $generatorBusy,
                    error: $generatorError,
                    onGenerate: { generateAccessKey(for: agent) },
                    onCancel: closeGenerator
                )
            }
        }
    }

    // MARK: - Unassigned (no address yet)

    private func unassignedRow(for agent: Agent) -> some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: "person.fill")
                .glyphSize(10)
                .foregroundColor(theme.text.link)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: theme.space.s2) {
                Text(agent.name)
                    .catalogTypography(.label, theme: theme, fallback: SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                Text("No address", bundle: .module)
                    .catalogTypography(.body, theme: theme, fallback: SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }

            Spacer()

            Button(action: { generateAddress(for: agent) }) {
                HStack(spacing: theme.space.s4) {
                    Image(systemName: "key.fill")
                    Text("Generate", bundle: .module)
                }
            }
            .assignedSettingsButtonStyle(.primary, size: .compact)
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s8)
        .settingsChrome(.inset)
    }

    // MARK: - Actions

    private func toggleExpanded(_ id: UUID) {
        if expandedAgentId == id {
            expandedAgentId = nil
        } else {
            expandedAgentId = id
        }
    }

    private func generateAddress(for agent: Agent) {
        errorMessage = nil
        do {
            try agentManager.assignAddress(to: agent)
            onChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func rotateKey(for agent: Agent) {
        errorMessage = nil
        do {
            guard let rotation = try agentManager.rotateAddress(of: agent) else { return }
            restartServerIfRunning()
            // The relay and every workspace share pin the OLD address; move
            // them or the agent goes dark for teammates and other devices.
            RelayTunnelManager.shared.handleAddressRotated(
                agentId: rotation.agentId, previousAddress: rotation.previousAddress
            )
            if let previous = rotation.previousAddress {
                // Owner-device keys for the old address were revoked with
                // the rotation; drop their records so the device list is
                // accurate and the phone re-redeems against the new address.
                Task { await OwnerDeviceAccessHost.shared.forgetRecords(agentAddress: previous) }
            }
            onChange()
            if let previous = rotation.previousAddress, OsaurusRouter.isEnabled,
                let rotated = agentManager.agent(for: rotation.agentId)
            {
                Task { @MainActor in
                    let migration = await WorkspacesService.shared.migrateShares(from: previous, to: rotated)
                    if !migration.failed.isEmpty {
                        errorMessage = L(
                            "Key rotated, but \(migration.failed.count) workspace share(s) still point at the old address. Re-share the agent there manually."
                        )
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revokeKey(for agent: Agent) {
        errorMessage = nil
        agentManager.revokeAddress(of: agent)
        restartServerIfRunning()
        onChange()
    }

    private func revokeAccessKey(_ id: UUID) {
        do {
            try AccessKeyLifecycleService.shared.revokeAndRemove(id: id)
            restartServerIfRunning()
            onChange()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func accessKeys(for agent: Agent) -> [AccessKeyInfo] {
        guard let address = agent.agentAddress else { return [] }
        return APIKeyManager.shared
            .listKeys(forAudience: address)
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func openGenerator(for agent: Agent) {
        generatorAgent = agent
        generatorLabel = ""
        generatorError = nil
        generatorBusy = false
        generatorExpiration = .days90
    }

    private func closeGenerator() {
        generatorAgent = nil
        generatorLabel = ""
        generatorError = nil
        generatorBusy = false
    }

    private func generateAccessKey(for agent: Agent) {
        let label = generatorLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, let agentKeyPath = agent.agentKeyPath else { return }

        generatorBusy = true
        generatorError = nil

        do {
            let result = try AccessKeyLifecycleService.shared.create(
                label: label,
                expiration: generatorExpiration,
                agentKeyPath: agentKeyPath
            )
            lastGeneratedKey = result.fullKey
            closeGenerator()
            restartServerIfRunning()
            onChange()
        } catch {
            generatorError = error.localizedDescription
            generatorBusy = false
        }
    }

    private func copyAddress(_ address: OsaurusID) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        withAnimation { copiedAddress = address }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copiedAddress = nil }
        }
    }

    private func restartServerIfRunning() {
        guard server.isRunning else { return }
        Task { await server.restartServer() }
    }
}

// MARK: - Generated Access Key Banner

private struct GeneratedAccessKeyBanner: View {
    @Environment(\.theme) private var inheritedTheme
    @Environment(\.isEnabled) private var inspectionEnabled
    private var theme: any ThemeProtocol { inheritedTheme }
    let key: String
    let onDismiss: () -> Void

    var body: some View {
        SettingsCallout(
            icon: "exclamationmark.triangle.fill",
            title: "Copy this key now. It won't be shown again.",
            message: "Anyone with this key can call the API.",
            tone: .warning
        ) {
            SettingsCodeBlock(code: key, wraps: false)
            SettingsButton(.secondary, "Dismiss", size: .compact, action: onDismiss)
        }
    }
}

// MARK: - Devices Link

/// This Mac's device record lives with the account's other devices on
/// Sharing → Devices; Osaurus ID only points there.
private struct DevicesLinkSection: View {
    var body: some View {
        SettingsSection(title: "Devices") {
            SettingsLinkRow(
                title: "This Mac and Your Other Devices",
                description: "Pairing, sync and each device's ID live in Sharing → Devices.",
                icon: "arrow.right",
                actionTitle: "Open"
            ) {
                ManagementStateManager.shared.selectedTab = .devices
            }
        }
    }
}

// MARK: - Reusable Section Container

