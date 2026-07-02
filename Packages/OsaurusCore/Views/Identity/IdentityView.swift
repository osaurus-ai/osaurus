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
    @EnvironmentObject private var server: ServerController
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var hasAppeared = false
    @State private var phase: IdentityPhase = .checking
    @State private var drift: IdentityDrift?

    @State private var showRecoverSheet = false
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
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    phaseContent
                }
                .padding(24)
                .settingsLandingAnchor("identity.keys")
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .onAppear {
            checkIdentityStatus()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .sheet(isPresented: $showRecoverSheet) {
            RecoverFromMnemonicSheet(
                drift: drift ?? IdentityDrift(mismatchedAgents: [], staleAccessKeys: []),
                onRecovered: handleRecovered,
                onCancel: { showRecoverSheet = false }
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
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 200)
        case .noIdentity:
            IdentitySetupCard(onCreated: handleIdentityCreated)
        case .ready(let osaurusId, let deviceId):
            readyContent(osaurusId: osaurusId, deviceId: deviceId)
        }
    }

    @ViewBuilder
    private func readyContent(osaurusId: OsaurusID, deviceId: String) -> some View {
        if let drift, drift.hasDrift {
            IdentityDriftBanner(
                drift: drift,
                onRecover: { showRecoverSheet = true },
                onRepair: { showRepairConfirm = true },
                onReset: { showResetConfirm = true }
            )
        }

        if let lastActionResult {
            actionResultBanner(lastActionResult)
        }

        MasterAddressSection(
            osaurusId: osaurusId,
            isLoadingPhrase: isLoadingRecoveryPhrase,
            onViewRecoveryPhrase: viewRecoveryPhrase
        )
        AgentAddressesSection(
            masterAddress: osaurusId,
            mismatchedAgentIds: Set((drift?.mismatchedAgents ?? []).map(\.id)),
            onChange: { runRefresh() }
        )
        DeviceSection(deviceId: deviceId)
        DangerZoneSection(onReset: { showResetConfirm = true })
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeaderWithActions(
            title: L("Identity"),
            subtitle: subtitleText
        ) {
            EmptyView()
        }
    }

    private var subtitleText: String {
        switch phase {
        case .checking:
            return "Loading identity..."
        case .noIdentity:
            return "Set up your Osaurus Identity"
        case .ready:
            return drift?.hasDrift == true ? "Identity drift detected" : "Your identity is active"
        }
    }

    private var repairConfirmMessage: LocalizedStringKey {
        let agents = drift?.mismatchedAgents.count ?? 0
        let keys = drift?.staleAccessKeys.count ?? 0
        return LocalizedStringKey(
            "Repair will derive fresh addresses for \(agents) agent(s) and revoke \(keys) stale access key(s) under the current master. Existing pairings and clients holding those keys will stop working until they're re-issued."
        )
    }

    private func actionResultBanner(_ result: ActionResult) -> some View {
        let tint = result.isError ? theme.errorColor : theme.successColor
        return HStack(spacing: 8) {
            Image(systemName: result.isError ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint)
            Text(result.message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(tint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: { lastActionResult = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
                    .padding(4)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(tint.opacity(0.10))
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
            let (newPhase, newDrift): (IdentityPhase, IdentityDrift?) = await Task.detached(
                priority: .userInitiated
            ) {
                do {
                    let deviceId = try DeviceKey.currentDeviceId()
                    let context = OsaurusIdentityContext.biometric()
                    var masterKeyData = try MasterKey.getPrivateKey(context: context)
                    defer { masterKeyData.zeroOut() }

                    let osaurusId = try deriveOsaurusId(from: masterKeyData)

                    let accessKeys = APIKeyManager.shared.listKeys()
                    let diagnosed = IdentityHealthCheck.diagnose(
                        masterKey: masterKeyData,
                        agents: agents,
                        accessKeys: accessKeys
                    )
                    return (.ready(osaurusId: osaurusId, deviceId: deviceId), diagnosed)
                } catch {
                    return (.noIdentity, nil)
                }
            }.value

            phase = newPhase
            drift = newDrift
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

    private func handleRecovered() {
        showRecoverSheet = false
        lastActionResult = ActionResult(
            message: "Master key restored from recovery phrase.",
            isError: false
        )
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
    @Environment(\.theme) private var theme

    let drift: IdentityDrift
    let onRecover: () -> Void
    let onRepair: () -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.errorColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identity drift detected", bundle: .module)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(theme.errorColor)
                    Text(summary)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            Text(
                "Your current Master Key no longer matches the addresses your agents and access keys were derived from. This usually means a Master Key was created on top of an existing one — for example, by a re-run of onboarding.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(action: onRecover) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Recover from phrase", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor)
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: onRepair) {
                    HStack(spacing: 6) {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Repair forward", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.tertiaryBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.inputBorder, lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: onReset) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Reset identity", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundColor(theme.errorColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.errorColor.opacity(0.10))
                    )
                }
                .buttonStyle(PlainButtonStyle())

                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.errorColor.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.errorColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private var summary: String {
        let agents = drift.mismatchedAgents.count
        let keys = drift.staleAccessKeys.count
        switch (agents, keys) {
        case (0, 0): return "Drift detected"
        case (let a, 0): return "\(a) agent address(es) no longer derive from this master."
        case (0, let k): return "\(k) access key(s) signed by a previous master."
        case (let a, let k):
            return "\(a) agent address(es) and \(k) access key(s) reference a previous master."
        }
    }
}

// MARK: - Danger Zone

private struct DangerZoneSection: View {
    @Environment(\.theme) private var theme
    let onReset: () -> Void

    var body: some View {
        IdentitySection(title: L("DANGER ZONE"), icon: "exclamationmark.triangle.fill") {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reset Identity", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "Wipes your signature, every agent address, and every access key, including the backup in your iCloud Keychain. Onboarding will start over.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(action: onReset) {
                    Text("Reset…", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.errorColor)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.errorColor.opacity(0.10))
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
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
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let onCreated: (IdentityInfo) -> Void

    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 40)

            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 48))
                .foregroundStyle(theme.accentColor)

            VStack(spacing: 8) {
                Text("Create Your Osaurus Identity", bundle: .module)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(theme.primaryText)

                Text(
                    "Generate a cryptographic identity stored securely\nin your iCloud Keychain and Secure Enclave.",
                    bundle: .module
                )
                .font(.system(size: 14))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.errorColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.errorColor.opacity(0.1))
                    )
            }

            Button(action: createIdentity) {
                HStack(spacing: 8) {
                    if isCreating {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "key.fill")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    Text("Generate Identity", bundle: .module)
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(theme.accentColor)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isCreating)

            Spacer().frame(height: 40)
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
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
    @Environment(\.theme) private var theme

    let words: [String]
    let error: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your recovery phrase", bundle: .module)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(theme.primaryText)
                    Text(
                        "Save it somewhere safe. Anyone with these words can recover your identity.",
                        bundle: .module
                    )
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(PlainButtonStyle())
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
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.accentColor)
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(theme.primaryBackground)
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.errorColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Couldn't load your phrase", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.errorColor)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.errorColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.errorColor.opacity(0.20), lineWidth: 1)
                )
        )
    }
}

// MARK: - Master Address Section

private struct MasterAddressSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let osaurusId: OsaurusID
    let isLoadingPhrase: Bool
    let onViewRecoveryPhrase: () -> Void

    @State private var copied = false

    var body: some View {
        IdentitySection(title: L("MASTER ADDRESS"), icon: "person.badge.key.fill") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Master Address", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(theme.secondaryText)
                        Text(osaurusId)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundColor(theme.primaryText)
                            .textSelection(.enabled)
                    }

                    Spacer()

                    Button(action: onViewRecoveryPhrase) {
                        HStack(spacing: 4) {
                            if isLoadingPhrase {
                                ProgressView()
                                    .scaleEffect(0.55)
                                    .frame(width: 11, height: 11)
                            } else {
                                Image(systemName: "key.viewfinder")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            Text("View recovery phrase", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .disabled(isLoadingPhrase)

                    Button(action: copyId) {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                            Text(copied ? L("Copied") : L("Copy"))
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(copied ? theme.successColor : theme.secondaryText)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(theme.tertiaryBackground)
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                }

                Divider().background(theme.secondaryBorder)

                HStack(spacing: 24) {
                    statusField(
                        label: L("Recovery"),
                        value: L("Backed up in iCloud Keychain"),
                        icon: "checkmark.shield.fill",
                        color: theme.successColor
                    )
                    statusField(label: L("Status"), value: L("Active"), icon: "circle.fill", color: theme.successColor)
                }
            }
        }
    }

    private func statusField(label: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                Text(value)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
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
    private var theme: ThemeProtocol { themeManager.currentTheme }

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
        IdentitySection(title: L("AGENT ADDRESSES"), icon: "person.2.badge.key.fill") {
            VStack(alignment: .leading, spacing: 10) {
                if customAgents.isEmpty {
                    Text("No agents yet — create one in the Agents tab", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.vertical, 4)
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
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.errorColor)
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
        HStack(spacing: 10) {
            Image(systemName: "person.fill")
                .font(.system(size: 10))
                .foregroundColor(theme.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.secondaryText)
                Text("No address", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer()

            Button(action: { generateAddress(for: agent) }) {
                HStack(spacing: 4) {
                    Image(systemName: "key.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Generate", bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(theme.accentColor)
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.tertiaryBackground.opacity(0.5))
        )
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
            try agentManager.rotateAddress(of: agent)
            restartServerIfRunning()
            onChange()
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
        guard !label.isEmpty, let agentIndex = agent.agentIndex else { return }

        generatorBusy = true
        generatorError = nil

        do {
            let result = try AccessKeyLifecycleService.shared.create(
                label: label,
                expiration: generatorExpiration,
                agentIndex: agentIndex
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
    @Environment(\.theme) private var theme
    let key: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Text("Copy this key now. It won't be shown again.", bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(theme.tertiaryText)
                        .padding(4)
                }
                .buttonStyle(PlainButtonStyle())
            }

            HStack(spacing: 8) {
                Text(key)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .textSelection(.enabled)
                    .lineLimit(1)

                Spacer()

                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                        Text("Copy", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(theme.accentColor)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.warningColor.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.warningColor.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.warningColor.opacity(0.15), lineWidth: 1)
                )
        )
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
    }
}

// MARK: - Device Section

private struct DeviceSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let deviceId: String

    var body: some View {
        IdentitySection(title: L("DEVICES"), icon: "desktopcomputer") {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 20))
                    .foregroundColor(theme.accentColor)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(theme.accentColor.opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Host.current().localizedName ?? "This Mac")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text("(this device)", bundle: .module)
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                    Text("Device ID: \(deviceId)", bundle: .module)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                }

                Spacer()

                HStack(spacing: 4) {
                    Circle()
                        .fill(theme.successColor)
                        .frame(width: 6, height: 6)
                    Text("Active", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(theme.successColor)
                }
            }
        }
    }
}

// MARK: - Reusable Section Container

private struct IdentitySection<Content: View>: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)

                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.secondaryText)
                    .tracking(0.5)
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
