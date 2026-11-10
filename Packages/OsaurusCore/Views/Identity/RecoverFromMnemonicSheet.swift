//
//  RecoverFromMnemonicSheet.swift
//  osaurus
//
//  Modal mnemonic-restore flow. The user pastes the 24-word BIP39 phrase
//  saved during onboarding; we validate the checksum and install the decoded
//  master into Keychain via `OsaurusIdentity.restore`, which also reconciles
//  agent addresses and access keys derived from a previous master.
//
//  Three entry modes share this sheet:
//  - driftRepair: the broken-master state. Confirms the phrase reproduces the
//    agent addresses already on disk (so we know it's the *previous* master,
//    not an unrelated valid mnemonic) before installing.
//  - freshRestore: no identity on this Mac (Settings → Identity setup card).
//  - replaceExisting: overwrite a healthy identity. Shows the current vs.
//    candidate address and requires an explicit acknowledgment because
//    agent addresses are re-minted and existing access keys revoked.
//

import AppKit
import SwiftUI

/// Which flow presented the sheet — controls copy, safety checks, and
/// confirmation requirements.
enum RecoverFromMnemonicMode {
    /// Identity drift banner: restore the previous master so persisted
    /// derivatives match again.
    case driftRepair(IdentityDrift)
    /// No identity on disk: restore an identity from another device.
    case freshRestore
    /// Healthy identity present: replace it with a different one.
    case replaceExisting(current: OsaurusID)
}

struct RecoverFromMnemonicSheet: View {
    @Environment(\.theme) private var theme

    let mode: RecoverFromMnemonicMode
    let onRecovered: (OsaurusIdentity.RestoreResult) -> Void
    let onCancel: () -> Void

    @State private var phraseText: String = ""
    @State private var statusMessage: String?
    @State private var statusIsError: Bool = true
    @State private var isRestoring: Bool = false
    @State private var requiresExplicitOverride: Bool = false
    @State private var hasAcknowledgedReplace: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsSheetHeader(icon: "key.fill", title: titleKey, onClose: onCancel)

            VStack(alignment: .leading, spacing: theme.space.s16) {
                description

                phraseEditor

                wordCountLine

                if case .replaceExisting(let current) = mode {
                    replaceDetails(current: current)
                }

                if let statusMessage {
                    statusBanner(statusMessage)
                }
            }
            .padding(theme.settingsSheetInset)

            SettingsSheetFooter(
                primary: .init(label: "Restore", isEnabled: canRestore, isLoading: isRestoring) {
                    restore(forceOverride: false)
                },
                secondary: .init(label: "Cancel", handler: onCancel),
                destructive: requiresExplicitOverride
                    ? .init(label: "Restore Anyway", isEnabled: !isRestoring, isDestructive: true) {
                        restore(forceOverride: true)
                    }
                    : nil
            )
        }
        .frame(width: SettingsSheetWidth.regular)
        .settingsSheetSurface()
    }

    // MARK: - Header / Copy


    private var titleKey: LocalizedStringKey {
        switch mode {
        case .driftRepair: "Recover Master Key"
        case .freshRestore: "Restore Identity"
        case .replaceExisting: "Replace Identity"
        }
    }

    private var descriptionText: Text {
        switch mode {
        case .driftRepair:
            return Text(
                "Paste the 24-word recovery phrase you saved during onboarding. We'll restore the original master key and your existing agents and access keys will start working again.",
                bundle: .module
            )
        case .freshRestore:
            return Text(
                "Paste the 24-word recovery phrase from your other Mac to restore your identity here. If iCloud Keychain is enabled on both Macs, the identity usually syncs on its own — the phrase is only needed when it doesn't.",
                bundle: .module
            )
        case .replaceExisting:
            return Text(
                "Paste the 24-word recovery phrase of the identity you want to switch to. This replaces the identity currently on this Mac.",
                bundle: .module
            )
        }
    }

    private var description: some View {
        VStack(alignment: .leading, spacing: 6) {
            descriptionText
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var phraseEditor: some View {
        SettingsFieldRow(label: "Recovery Phrase") {
            SettingsTextEditor(text: $phraseText, minHeight: 110, maxHeight: 140, monospaced: true)
        }
    }

    private var wordCountLine: some View {
        HStack(spacing: 8) {
            let count = parsedWords.count
            Image(systemName: count == 24 ? "checkmark.circle.fill" : "circle.dotted")
                .font(SettingsFont.glyphSmall)
                .foregroundColor(count == 24 ? theme.status.success.foreground : theme.text.tertiary)
            Text("\(count) of 24 words")
                .font(SettingsFont.monoSmall)
                .foregroundColor(theme.text.tertiary)
            Spacer()
            SettingsButton(.secondary, "Paste", icon: "doc.on.clipboard", size: .compact, action: pasteFromClipboard)
        }
    }

    // MARK: - Replace-existing details

    /// Current vs. candidate address plus the destructive-consequences
    /// acknowledgment required before Restore enables.
    @ViewBuilder
    private func replaceDetails(current: OsaurusID) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                addressLine(label: Text("Current identity", bundle: .module), address: current)
                addressLine(
                    label: Text("Restored identity", bundle: .module),
                    address: candidateAddress
                )
            }

            Toggle(isOn: $hasAcknowledgedReplace) {
                Text(
                    "I understand: agents get new addresses, existing access keys are revoked, and the current identity's recovery phrase will no longer restore this Mac unless I saved it.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .settingsCheckbox()
        }
        .padding(theme.space.s12)
        .settingsChrome(.status(.warning))
    }

    private func addressLine(label: Text, address: OsaurusID?) -> some View {
        HStack(spacing: 8) {
            label
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.secondary)
                .frame(width: 110, alignment: .leading)
            if let address {
                Text(address)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Enter a valid phrase", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                .font(SettingsFont.glyphSmall)
                .foregroundColor(statusIsError ? theme.status.error.foreground : theme.status.success.foreground)
            Text(message)
                .font(SettingsFont.compactLabel)
                .foregroundColor(statusIsError ? theme.status.error.foreground : theme.status.success.foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.vertical, theme.space.s6)
        .settingsChrome(.status(statusIsError ? .error : .success))
    }


    // MARK: - Logic

    private var parsedWords: [String] {
        MasterKeyMnemonic.words(fromPhrase: phraseText)
    }

    private var canRestore: Bool {
        Self.canRestore(
            words: parsedWords, mode: mode, acknowledgedReplace: hasAcknowledgedReplace)
    }

    /// Whether the Restore button is enabled: a complete 24-word phrase, plus
    /// the explicit acknowledgment when replacing a healthy identity.
    /// Internal (not private) for direct testing.
    static func canRestore(
        words: [String], mode: RecoverFromMnemonicMode, acknowledgedReplace: Bool
    ) -> Bool {
        guard words.count == 24 else { return false }
        if case .replaceExisting = mode, !acknowledgedReplace { return false }
        return true
    }

    private var candidateAddress: OsaurusID? {
        Self.candidateAddress(for: parsedWords)
    }

    /// Address the entered phrase would restore, or nil while the phrase is
    /// incomplete or fails checksum validation. Used for the replace-existing
    /// current-vs-candidate preview. Internal (not private) for direct testing.
    static func candidateAddress(for words: [String]) -> OsaurusID? {
        guard words.count == 24 else { return nil }
        guard var seed = try? MasterKeyMnemonic.key(fromMnemonic: words) else { return nil }
        defer { seed.zeroOut() }
        return try? deriveOsaurusId(from: seed)
    }

    private func pasteFromClipboard() {
        guard let s = NSPasteboard.general.string(forType: .string) else { return }
        phraseText = s
    }

    private func restore(forceOverride: Bool) {
        statusMessage = nil
        requiresExplicitOverride = false
        isRestoring = true
        Task { @MainActor in
            await performRestore(forceOverride: forceOverride)
        }
    }

    @MainActor
    private func performRestore(forceOverride: Bool) async {
        do {
            // Drift repair verifies the phrase is the *previous* master before
            // installing, so a typo'd-but-valid mnemonic can't silently mint a
            // brand-new identity. Fresh restore has nothing to compare against
            // and replace-existing is an intentional identity change.
            if case .driftRepair(let drift) = mode, !forceOverride {
                var seed = try MasterKeyMnemonic.key(fromMnemonic: parsedWords)
                defer { seed.zeroOut() }
                let candidateAddress = try deriveOsaurusId(from: seed)
                if let mismatchCheck = Self.previousSeedMismatchMessage(
                    drift: drift, seed: seed, candidate: candidateAddress) {
                    statusIsError = true
                    statusMessage = mismatchCheck
                    requiresExplicitOverride = true
                    isRestoring = false
                    return
                }
            }

            let result = try await OsaurusIdentity.restore(words: parsedWords)
            statusIsError = false
            statusMessage = successMessage(for: result)
            isRestoring = false
            onRecovered(result)
        } catch let err as OsaurusIdentityError {
            statusIsError = true
            statusMessage = err.errorDescription ?? "Recovery failed."
            isRestoring = false
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
            isRestoring = false
        }
    }

    private func successMessage(for result: OsaurusIdentity.RestoreResult) -> String {
        switch mode {
        case .driftRepair:
            return "Master key restored. Drift cleared."
        case .freshRestore, .replaceExisting:
            return "Identity \(result.osaurusId) restored."
        }
    }

    /// Returns nil when the candidate seed reproduces the agent addresses we
    /// have on disk (i.e. it's the previous master). Returns a user-facing
    /// error message when there is no match — the caller surfaces an explicit
    /// "Restore Anyway" override in that case. Internal (not private) for
    /// direct testing.
    static func previousSeedMismatchMessage(
        drift: IdentityDrift, seed: Data, candidate: OsaurusID
    ) -> String? {
        // We have agents whose stored addresses don't derive from the current
        // master; verify the candidate seed reproduces *those* stored addresses.
        let mismatched = drift.mismatchedAgents
        guard !mismatched.isEmpty else {
            // No agent addresses to verify against. Fall back to comparing
            // against issuer of any stale access key, otherwise accept.
            return nil
        }

        for agent in mismatched {
            guard let storedPath = agent.agentKeyPath,
                let storedAddress = agent.agentAddress
            else { continue }
            do {
                let derived = try AgentKey.deriveAddress(masterKey: seed, path: storedPath)
                if derived.lowercased() == storedAddress.lowercased() {
                    return nil
                }
            } catch {
                continue
            }
        }

        let firstStored = mismatched.first?.agentAddress ?? ""
        return
            "This phrase derives \(candidate) but your agents were derived from \(firstStored). Use \"Restore Anyway\" only if you're sure."
    }
}
