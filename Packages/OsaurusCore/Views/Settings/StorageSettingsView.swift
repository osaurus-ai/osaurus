//
//  StorageSettingsView.swift
//  osaurus
//
//  Settings panel for at-rest encryption: explains the encryption
//  posture in plain language and exposes the two admin actions —
//  export plaintext backup and rotate the storage key — with
//  guardrails so a user can't accidentally destroy their data.
//
//  Surfaced by the WhatsNew page action `openStorageSettings` and
//  reachable from the management settings sidebar.
//

import AppKit
import SwiftUI

public struct StorageSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var keyPresent: Bool = false
    @State private var lastSummary: String = ""
    @State private var isWorking: Bool = false
    @State private var showRotateConfirm: Bool = false
    @State private var errorMessage: String?

    @State private var hasExportedBackupThisSession: Bool = false
    @State private var showTechnicalDetails: Bool = false

    @State private var hasAppeared = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            headerView
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : -10)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    aboutCard
                    statusCard
                    actionsCard
                    footnote
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
        .task { await refresh() }
        .onAppear {
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .alert("Rotate the storage key?", isPresented: $showRotateConfirm) {
            if !hasExportedBackupThisSession {
                Button(localized: "Back up first…") { runExport(reason: .beforeRotate) }
            }
            Button(localized: "Cancel", role: .cancel) {}
            Button(localized: "Rotate", role: .destructive) { rotateKey() }
        } message: {
            Text(rotateAlertMessage)
        }
    }

    // MARK: - Derived state

    private var rotateAlertMessage: String {
        if hasExportedBackupThisSession {
            return
                "A new 256-bit key will be generated and every encrypted database + file under ~/.osaurus will be re-encrypted against it. The old key is destroyed — backups made under the old key will no longer be readable on this Mac."
        }
        return
            "A new 256-bit key will be generated and every encrypted database + file under ~/.osaurus will be re-encrypted against it. The old key is destroyed — backups made under the old key will no longer be readable on this Mac. We strongly recommend exporting a plaintext backup first."
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeader(
            title: L("Encrypted storage"),
            subtitle: L("End-to-end at-rest encryption for your local data")
        )
    }

    // MARK: - About card

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("About encrypted storage", bundle: .module)
            } icon: {
                Image(systemName: "lock.shield.fill")
                    .foregroundColor(theme.accentColor)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(theme.primaryText)

            VStack(alignment: .leading, spacing: 8) {
                aboutRow(
                    icon: "doc.text.magnifyingglass",
                    text:
                        "Chats, long-term memory, methods, tool indexes, and configuration files are encrypted at rest with AES-256 (SQLCipher)."
                )
                aboutRow(
                    icon: "key.fill",
                    text:
                        "The 256-bit encryption key lives in your macOS Keychain. It never leaves this Mac and is not synced to iCloud."
                )
                aboutRow(
                    icon: "checkmark.shield",
                    text:
                        "If you're moving Macs or wiping macOS, export a plaintext backup first. Otherwise no action is needed — encryption runs automatically."
                )
            }
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

    private func aboutRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 16, alignment: .center)
                .padding(.top, 2)
            Text(LocalizedStringKey(text), bundle: .module)
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: keyPresent ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(keyPresent ? theme.successColor : theme.warningColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        keyPresent ? "Encryption key installed" : "No encryption key found",
                        bundle: .module
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)

                    Text(LocalizedStringKey(statusSubtitle), bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
            }

            DisclosureGroup(isExpanded: $showTechnicalDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Service: com.osaurus.storage", bundle: .module)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .textSelection(.enabled)
                    Text("Account: data-encryption-key", bundle: .module)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .textSelection(.enabled)
                    Text("Cipher: AES-256-CBC + HMAC-SHA512, page size 4096, kdf_iter 256000", bundle: .module)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .textSelection(.enabled)
                }
                .padding(.top, 6)
            } label: {
                Text("Show technical details", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .accentColor(theme.tertiaryText)
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

    /// Single source of truth for the small reassurance / status
    /// line under the status card title.
    private var statusSubtitle: String {
        if !keyPresent {
            return "Generate a key from the Keychain to encrypt new data."
        }
        return "Your data is encrypted at rest. No action needed."
    }

    // MARK: - Actions card

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Backup & key", bundle: .module)
            } icon: {
                Image(systemName: "archivebox")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(theme.primaryText)

            VStack(alignment: .leading, spacing: 12) {
                actionRow(
                    icon: "square.and.arrow.up",
                    title: "Export plaintext backup…",
                    buttonLabel: "Export…",
                    subtitle:
                        "Decrypts every artifact under ~/.osaurus and writes a plaintext copy to the destination of your choice. Recommended before reinstalling macOS or moving Macs.",
                    isPrimary: true,
                    isDisabled: isWorking
                ) {
                    runExport(reason: .userInitiated)
                }

                Divider().background(theme.primaryBorder.opacity(0.2))

                actionRow(
                    icon: "key.fill",
                    title: "Rotate storage key",
                    buttonLabel: "Rotate",
                    subtitle: "Generate a new 256-bit key and re-encrypt every artifact. The old key is destroyed.",
                    isPrimary: false,
                    isDisabled: isWorking
                ) {
                    showRotateConfirm = true
                }
            }

            if let err = errorMessage {
                statusLine(text: err, color: theme.errorColor, icon: "exclamationmark.triangle")
            }
            if !lastSummary.isEmpty {
                statusLine(text: lastSummary, color: theme.successColor, icon: "checkmark.circle")
            }
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

    @ViewBuilder
    private func actionRow(
        icon: String,
        title: String,
        buttonLabel: String,
        subtitle: String,
        isPrimary: Bool,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(LocalizedStringKey(subtitle), bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            actionButton(
                icon: icon,
                label: buttonLabel,
                isPrimary: isPrimary,
                isDisabled: isDisabled,
                action: action
            )
        }
    }

    @ViewBuilder
    private func actionButton(
        icon: String,
        label: String,
        isPrimary: Bool,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(LocalizedStringKey(label), bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(isPrimary ? .white : theme.primaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(actionButtonBackground(isPrimary: isPrimary, isDisabled: isDisabled))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isDisabled)
    }

    @ViewBuilder
    private func actionButtonBackground(isPrimary: Bool, isDisabled: Bool) -> some View {
        if isPrimary {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.accentColor.opacity(isDisabled ? 0.4 : 1.0))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.tertiaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        }
    }

    private func statusLine(text: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Footnote

    private var footnote: some View {
        Text(
            "Wiping the macOS Keychain or migrating to a new Mac without iCloud Keychain sync makes encrypted storage unrecoverable. Take a plaintext backup first if you need to migrate.",
            bundle: .module
        )
        .font(.system(size: 11))
        .foregroundColor(theme.secondaryText.opacity(0.85))
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    private func refresh() async {
        keyPresent = StorageKeyManager.shared.keyExists()
    }

    /// Why an export is being run — drives the open-panel copy,
    /// the success summary line, and what happens after success
    /// (reveal in Finder vs. re-present the rotate confirmation).
    /// Consolidates what used to be two near-duplicate methods.
    private enum ExportReason {
        case userInitiated
        case beforeRotate
    }

    private func runExport(reason: ExportReason) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        switch reason {
        case .userInitiated:
            panel.title = L("Choose backup destination")
            panel.message = L("Pick an empty folder; the plaintext export will be written here.")
        case .beforeRotate:
            panel.title = L("Back up before rotating")
            panel.message =
                L(
                    "Pick a folder to write the plaintext backup to. We'll re-prompt for rotation after the backup completes."
                )
        }
        Task { @MainActor in
            guard await panel.beginModal() == .OK, let dest = panel.url else { return }

            let backupDir = dest.appendingPathComponent("osaurus-plaintext-backup", isDirectory: true)
            isWorking = true
            errorMessage = nil
            do {
                let summary = try await StorageExportService.shared.exportPlaintextBackup(to: backupDir)
                self.isWorking = false
                self.hasExportedBackupThisSession = true
                switch reason {
                case .userInitiated:
                    self.lastSummary =
                        "Wrote \(summary.databasesExported) databases, \(summary.jsonFilesDecrypted) config files, and \(summary.blobsDecrypted) attachments to \(summary.destination.lastPathComponent)."
                    NSWorkspace.shared.activateFileViewerSelecting([backupDir])
                case .beforeRotate:
                    self.lastSummary =
                        "Backup written to \(summary.destination.lastPathComponent). You can now rotate the key safely."
                    self.showRotateConfirm = true
                }
            } catch {
                self.isWorking = false
                self.errorMessage = error.localizedDescription
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
                    self.hasExportedBackupThisSession = false
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
