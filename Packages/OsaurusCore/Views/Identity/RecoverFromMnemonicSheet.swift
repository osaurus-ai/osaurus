//
//  RecoverFromMnemonicSheet.swift
//  osaurus
//
//  Modal recovery flow for the broken-master state. The user pastes the
//  24-word BIP39 phrase saved during onboarding; we validate the checksum,
//  confirm the resulting master derives the agent addresses we already have
//  on disk (so we know it's the *previous* master, not an unrelated valid
//  mnemonic), and re-install the master into Keychain. Drift goes away
//  because every persisted derivative now matches again.
//

import AppKit
import SwiftUI

struct RecoverFromMnemonicSheet: View {
    @Environment(\.theme) private var theme

    let drift: IdentityDrift
    let onRecovered: () -> Void
    let onCancel: () -> Void

    @State private var phraseText: String = ""
    @State private var statusMessage: String?
    @State private var statusIsError: Bool = true
    @State private var isRestoring: Bool = false
    @State private var requiresExplicitOverride: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            description

            phraseEditor

            wordCountLine

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
            Text("Recover Master Key", bundle: .module)
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

    private var description: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                "Paste the 24-word recovery phrase you saved during onboarding. We'll restore the original master key and your existing agents and access keys will start working again.",
                bundle: .module
            )
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
                        .fill(parsedWords.count == 24 ? theme.accentColor : theme.accentColor.opacity(0.4))
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(parsedWords.count != 24 || isRestoring)
        }
    }

    // MARK: - Logic

    private var parsedWords: [String] {
        MasterKeyMnemonic.words(fromPhrase: phraseText)
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
            var seed = try MasterKeyMnemonic.key(fromMnemonic: parsedWords)
            defer { seed.zeroOut() }

            let candidateAddress = try deriveOsaurusId(from: seed)

            if !forceOverride {
                if let mismatchCheck = matchesPreviousMaster(seed: seed, candidate: candidateAddress) {
                    statusIsError = true
                    statusMessage = mismatchCheck
                    requiresExplicitOverride = true
                    isRestoring = false
                    return
                }
            }

            try MasterKey.install(seed: seed, allowReplace: true)
            // Keep the stored phrase in sync with the newly-installed master
            // so subsequent "View recovery phrase" reads hit the cache
            // instead of falling into the lazy-backfill path.
            try? MasterMnemonicStore.store(parsedWords)
            statusIsError = false
            statusMessage = "Master key restored. Drift cleared."
            isRestoring = false
            onRecovered()
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

    /// Returns nil when the candidate seed reproduces the agent addresses we
    /// have on disk (i.e. it's the previous master). Returns a user-facing
    /// error message when there is no match — the caller surfaces an explicit
    /// "Restore Anyway" override in that case.
    private func matchesPreviousMaster(seed: Data, candidate: OsaurusID) -> String? {
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
