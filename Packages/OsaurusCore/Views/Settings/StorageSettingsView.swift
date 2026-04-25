//
//  StorageSettingsView.swift
//  osaurus
//
//  Settings panel for at-rest encryption: shows current state, lets
//  the user export a plaintext backup or rotate the storage key.
//
//  Surfaced by the WhatsNew page action `openStorageSettings` and
//  reachable from the Server settings tab via "Manage encrypted
//  storage…".
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct StorageSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var keyPresent: Bool = false
    @State private var lastSummary: String = ""
    @State private var isWorking: Bool = false
    @State private var showRotateConfirm: Bool = false
    @State private var errorMessage: String?

    @State private var lastOutcome: StorageMigrator.OutcomeSummary?
    @State private var keyMismatchTargets: [StorageMigrator.DatabaseTarget] = []

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            statusCard
            if let outcome = lastOutcome, !outcome.failedTargets.isEmpty {
                partialFailureCard(outcome: outcome)
            }
            if !keyMismatchTargets.isEmpty {
                keyMismatchCard
            }

            actions

            Spacer()

            footnote
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.primaryBackground)
        .environment(\.theme, themeManager.currentTheme)
        .task { await refresh() }
        .alert("Rotate the storage key?", isPresented: $showRotateConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Rotate", role: .destructive) { rotateKey() }
        } message: {
            Text(
                "A new 256-bit key will be generated and every encrypted database + file under ~/.osaurus will be re-encrypted against it. The old key is destroyed — backups made under the old key will no longer be readable on this Mac."
            )
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Encrypted storage")
                .font(.title.weight(.semibold))
                .foregroundStyle(theme.primaryText)
            Text(
                "Chat history, long-term memory, methods, tool indexes, and configuration files are encrypted at rest using SQLCipher (AES-256) and a key from your macOS Keychain."
            )
            .font(.callout)
            .foregroundStyle(theme.secondaryText)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: keyPresent ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(keyPresent ? Color.green : Color.orange)
                Text(keyPresent ? "Encryption key installed" : "No encryption key found")
                    .foregroundStyle(theme.primaryText)
                    .font(.headline)
            }
            Text("Service: com.osaurus.storage  ·  Account: data-encryption-key")
                .font(.caption.monospaced())
                .foregroundStyle(theme.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(theme.primaryBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10).stroke(theme.primaryBorder.opacity(0.3))
        )
    }

    /// Surfaces databases the migrator couldn't re-encrypt. The
    /// originals are still on disk under
    /// `~/.osaurus/.pre-encryption-backup/` so the user can recover
    /// or retry. Without this card the user has no way of knowing
    /// they're running in a partially-degraded mode.
    private func partialFailureCard(outcome: StorageMigrator.OutcomeSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
                Text("\(outcome.failedTargets.count) database(s) didn't migrate")
                    .foregroundStyle(theme.primaryText)
                    .font(.headline)
            }
            ForEach(outcome.failedTargets.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.key).font(.callout.weight(.medium))
                        .foregroundStyle(theme.primaryText)
                    Text(item.value)
                        .font(.caption)
                        .foregroundStyle(theme.secondaryText)
                }
            }
            Text(
                "Plaintext copies are preserved under ~/.osaurus/.pre-encryption-backup/. Re-launch Osaurus to retry, or use Export plaintext backup below to bundle them."
            )
            .font(.footnote)
            .foregroundStyle(theme.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.4)))
    }

    /// Shown when one or more encrypted DBs exist but can't be opened
    /// with the current Keychain key (Keychain wiped, restored from
    /// backup, etc.). The user has a chance to bail before the apps
    /// proceed to write fresh data on top.
    private var keyMismatchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "key.slash")
                    .foregroundStyle(Color.red)
                Text("Encryption key doesn't match the encrypted databases")
                    .foregroundStyle(theme.primaryText)
                    .font(.headline)
            }
            Text(
                "Your existing data was encrypted with a different key (likely from a previous install). Osaurus is opening it in degraded mode. Restore the original Keychain entry, or use Reset to start fresh — this will discard the unreadable data."
            )
            .font(.callout)
            .foregroundStyle(theme.secondaryText)

            Text(keyMismatchTargets.map(\.label).joined(separator: ", "))
                .font(.caption.monospaced())
                .foregroundStyle(theme.secondaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.red.opacity(0.4)))
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                exportBackup()
            } label: {
                Label("Export plaintext backup…", systemImage: "square.and.arrow.up")
            }
            .disabled(isWorking)

            Button(role: .destructive) {
                showRotateConfirm = true
            } label: {
                Label("Rotate storage key", systemImage: "key.fill")
            }
            .disabled(isWorking)

            if let err = errorMessage {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if !lastSummary.isEmpty {
                Text(lastSummary)
                    .font(.callout)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    private var footnote: some View {
        Text(
            "Wiping the macOS Keychain or migrating to a new Mac without iCloud Keychain sync makes encrypted storage unrecoverable. Take a plaintext backup first if you need to migrate."
        )
        .font(.footnote)
        .foregroundStyle(theme.secondaryText.opacity(0.85))
    }

    // MARK: - Actions

    private func refresh() async {
        keyPresent = StorageKeyManager.shared.keyExists()
        lastOutcome = await StorageMigrator.shared.loadLastOutcome()
        keyMismatchTargets = await StorageMigrator.shared.detectKeyMismatch()
    }

    private func exportBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose backup destination"
        panel.message = "Pick an empty folder; the plaintext export will be written here."
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let backupDir = dest.appendingPathComponent("osaurus-plaintext-backup", isDirectory: true)
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let summary = try await StorageExportService.shared.exportPlaintextBackup(to: backupDir)
                await MainActor.run {
                    self.isWorking = false
                    self.lastSummary =
                        "Wrote \(summary.databasesExported) databases, \(summary.jsonFilesDecrypted) config files, and \(summary.blobsDecrypted) attachments to \(summary.destination.lastPathComponent)."
                    NSWorkspace.shared.activateFileViewerSelecting([backupDir])
                }
            } catch {
                await MainActor.run {
                    self.isWorking = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func rotateKey() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                _ = try await StorageExportService.shared.rotateStorageKey()
                await MainActor.run {
                    self.isWorking = false
                    self.lastSummary = "Storage key rotated. All databases re-encrypted."
                }
                await refresh()
            } catch {
                await MainActor.run {
                    self.isWorking = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
