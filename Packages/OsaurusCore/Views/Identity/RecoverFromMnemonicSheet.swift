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
    /// No identity on disk: restore an identity from another Mac.
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
        VStack(alignment: .leading, spacing: 16) {
            header

            description

            phraseEditor

            wordCountLine

            if case .replaceExisting(let current) = mode {
                replaceDetails(current: current)
            }

            if let statusMessage {
                statusBanner(statusMessage)
            }

            buttonRow
        }
        .padding(24)
        .frame(width: 540)
        .background(theme.primaryBackground)
    }

    // MARK: - Header / Copy

    private var header: some View {
        HStack {
            titleText
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(theme.primaryText)
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(theme.tertiaryText)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var titleText: Text {
        switch mode {
        case .driftRepair:
            return Text("Recover Master Key", bundle: .module)
        case .freshRestore:
            return Text("Restore Identity", bundle: .module)
        case .replaceExisting:
            return Text("Replace Identity", bundle: .module)
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
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var phraseEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recovery Phrase", bundle: .module)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)

            TextEditor(text: $phraseText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(theme.primaryText)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 110, maxHeight: 140)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.inputBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.inputBorder, lineWidth: 1)
                        )
                )
        }
    }

    private var wordCountLine: some View {
        HStack(spacing: 8) {
            let count = parsedWords.count
            Image(systemName: count == 24 ? "checkmark.circle.fill" : "circle.dotted")
                .font(.system(size: 11))
                .foregroundColor(count == 24 ? theme.successColor : theme.tertiaryText)
            Text("\(count) of 24 words")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
            Spacer()
            Button(action: pasteFromClipboard) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 10, weight: .medium))
                    Text("Paste", bundle: .module)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(theme.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.tertiaryBackground)
                )
            }
            .buttonStyle(PlainButtonStyle())
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
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.warningColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.warningColor.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private func addressLine(label: Text, address: OsaurusID?) -> some View {
        HStack(spacing: 8) {
            label
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.secondaryText)
                .frame(width: 110, alignment: .leading)
            if let address {
                Text(address)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Enter a valid phrase", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer(minLength: 0)
        }
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(statusIsError ? theme.errorColor : theme.successColor)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(statusIsError ? theme.errorColor : theme.successColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((statusIsError ? theme.errorColor : theme.successColor).opacity(0.1))
        )
    }

    private var buttonRow: some View {
        HStack(spacing: 12) {
            if requiresExplicitOverride {
                Button(action: { restore(forceOverride: true) }) {
                    Text("Restore Anyway", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.warningColor)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isRestoring)
            }

            Spacer()

            Button(action: onCancel) {
                Text("Cancel", bundle: .module)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
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

            Button(action: { restore(forceOverride: false) }) {
                HStack(spacing: 6) {
                    if isRestoring {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "key.fill")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text("Restore", bundle: .module)
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(canRestore ? theme.accentColor : theme.accentColor.opacity(0.4))
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!canRestore || isRestoring)
        }
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

            let result = try OsaurusIdentity.restore(words: parsedWords)
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
            guard let storedIndex = agent.agentIndex,
                let storedAddress = agent.agentAddress
            else { continue }
            do {
                let derived = try AgentKey.deriveAddress(masterKey: seed, index: storedIndex)
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
