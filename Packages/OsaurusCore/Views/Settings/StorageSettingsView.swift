//
//  StorageSettingsView.swift
//  osaurus
//
//  Settings panel for at-rest encryption: explains the encryption
//  posture in plain language, surfaces real recovery situations
//  (key mismatch on a core DB) without false alarms (orphaned
//  plugin DBs from uninstalled plugins / leaked dev tests), and
//  exposes the two admin actions — export plaintext backup and
//  rotate the storage key — with guardrails so a user can't
//  accidentally destroy their data.
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

    @State private var lastOutcome: StorageMigrator.OutcomeSummary?
    @State private var keyMismatchTargets: [StorageMigrator.DatabaseTarget] = []
    @State private var hasExportedBackupThisSession: Bool = false
    @State private var showCleanupConfirm: Bool = false
    @State private var showTechnicalDetails: Bool = false
    @State private var showMismatchDetails: Bool = false

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

                    if !coreMismatchTargets.isEmpty {
                        coreKeyMismatchCard
                    } else if !pluginMismatchTargets.isEmpty {
                        pluginOrphanCard
                    }

                    if let outcome = lastOutcome, !outcome.failedTargets.isEmpty {
                        partialFailureCard(outcome: outcome)
                    }
                    if let outcome = lastOutcome, outcome.jsonFilesRecovered > 0 {
                        recoveryCard(outcome: outcome)
                    }

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
                Button("Back up first…") { runExport(reason: .beforeRotate) }
            }
            Button("Cancel", role: .cancel) {}
            Button("Rotate", role: .destructive) { rotateKey() }
        } message: {
            Text(rotateAlertMessage)
        }
        .alert(
            "Remove orphaned plugin data?",
            isPresented: $showCleanupConfirm
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { cleanupOrphans() }
        } message: {
            Text(
                "\(pluginMismatchTargets.count) plugin database(s) can't be opened with the current encryption key. They're almost always left over from uninstalled plugins or development test runs. Removing them deletes the corresponding folders under ~/.osaurus/Tools/. Real plugin data won't be touched."
            )
        }
    }

    // MARK: - Derived state

    private var coreMismatchTargets: [StorageMigrator.DatabaseTarget] {
        keyMismatchTargets.filter { $0.pluginId == nil }
    }

    private var pluginMismatchTargets: [StorageMigrator.DatabaseTarget] {
        keyMismatchTargets.filter { $0.pluginId != nil }
    }

    /// Rotation is unsafe when a core DB is in mismatch — the rotate
    /// path would re-encrypt the unreadable file under the new key
    /// and delete the chance to ever recover it. The button stays
    /// visible so the user knows the action exists, but the alert
    /// path is short-circuited.
    private var rotateBlocked: Bool { !coreMismatchTargets.isEmpty }

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
        if !coreMismatchTargets.isEmpty {
            return "Core data needs your attention — see the recovery card below."
        }
        if !pluginMismatchTargets.isEmpty {
            return "Your data is encrypted at rest. Stale plugin data is listed below."
        }
        return "Your data is encrypted at rest. No action needed."
    }

    // MARK: - Core key-mismatch card (loud red)

    /// Loud recovery card shown when one of the four core databases
    /// (chat history / memory / methods / tool index) can't be
    /// opened with the current Keychain key. This is the genuine
    /// "your data is encrypted with a different key than what's in
    /// my Keychain right now" situation. We block destructive
    /// actions (rotate) until the user takes a corrective step.
    private var coreKeyMismatchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Core data can't be decrypted", bundle: .module)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(theme.errorColor)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(theme.primaryText)

            Text(
                "Your existing data was encrypted with a different key — typically because the macOS Keychain was wiped, restored from a different machine, or a previous app version stored a different key. Osaurus is opening it in degraded mode.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(coreMismatchTargets, id: \.label) { target in
                    HStack(spacing: 8) {
                        Image(systemName: "lock.trianglebadge.exclamationmark")
                            .font(.system(size: 11))
                            .foregroundColor(theme.errorColor)
                        Text(target.label.capitalized)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                    }
                }
            }

            Text(
                "Restore the original Keychain entry to recover. Rotating the key in this state would permanently destroy the unreadable data.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.errorColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.errorColor.opacity(0.4), lineWidth: 1)
                )
        )
    }

    // MARK: - Plugin orphan card (quiet warning)

    /// Quieter informational card shown when only **plugin** DBs
    /// fail to decrypt. These are almost always left behind by
    /// uninstalled plugins or leaked development test runs (the
    /// `com.test.*` filter in `StorageMigrator.databaseTargets()`
    /// catches the historical dev-leak pattern; this card is the
    /// safety net for everything else). Loss of this data is
    /// tolerable, so we offer a one-click cleanup instead of a
    /// scary alarm.
    private var pluginOrphanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Orphaned plugin data", bundle: .module)
            } icon: {
                Image(systemName: "tray.full")
                    .foregroundColor(theme.warningColor)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(theme.primaryText)

            Text(
                "\(pluginMismatchTargets.count) plugin database(s) can't be opened with the current key. These are typically left behind when you uninstall a plugin. Your chats and configuration are unaffected.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(isExpanded: $showMismatchDetails) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pluginMismatchTargets, id: \.label) { target in
                        Text(target.label)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(theme.tertiaryText)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("Show details (\(pluginMismatchTargets.count))", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }
            .accentColor(theme.tertiaryText)

            Button {
                showCleanupConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Clean up orphaned plugin data", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(theme.warningColor)
                )
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(isWorking)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.warningColor.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.warningColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    // MARK: - Migration outcome cards

    /// Surfaces databases the migrator couldn't re-encrypt. The
    /// originals are still on disk under
    /// `~/.osaurus/.pre-encryption-backup/` so the user can recover
    /// or retry. Without this card the user has no way of knowing
    /// they're running in a partially-degraded mode.
    private func partialFailureCard(outcome: StorageMigrator.OutcomeSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("\(outcome.failedTargets.count) database(s) didn't migrate", bundle: .module)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(theme.warningColor)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(theme.primaryText)

            ForEach(outcome.failedTargets.sorted(by: { $0.key < $1.key }), id: \.key) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.key)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text(item.value)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
            }

            Text(
                "Plaintext copies are preserved under ~/.osaurus/.pre-encryption-backup/. Re-launch Osaurus to retry, or use Export plaintext backup below to bundle them.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.warningColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.warningColor.opacity(0.4), lineWidth: 1)
                )
        )
    }

    /// Shown after a v1→v2 launch where the migrator restored
    /// `.osec` JSON files back to plaintext (the recovery path —
    /// see `StorageMigrator.recoverEncryptedJSON`). Quiet
    /// confirmation that the user's agents/themes/config are back.
    private func recoveryCard(outcome: StorageMigrator.OutcomeSummary) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundColor(theme.accentColor)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    "Restored \(outcome.jsonFilesRecovered) configuration file(s)",
                    bundle: .module
                )
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.primaryText)
                Text(
                    "An earlier build encrypted these by mistake. They're now back as plaintext where the app expects them.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.accentColor.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.accentColor.opacity(0.25), lineWidth: 1)
                )
        )
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
                    isDisabled: isWorking,
                    disabledHelp: nil
                ) {
                    runExport(reason: .userInitiated)
                }

                Divider().background(theme.primaryBorder.opacity(0.2))

                actionRow(
                    icon: "key.fill",
                    title: "Rotate storage key",
                    buttonLabel: "Rotate",
                    subtitle: rotateBlocked
                        ? "Disabled while core data can't be decrypted. Rotating now would permanently destroy the unreadable data."
                        : "Generate a new 256-bit key and re-encrypt every artifact. The old key is destroyed.",
                    isPrimary: false,
                    isDisabled: isWorking || rotateBlocked,
                    disabledHelp: rotateBlocked
                        ? "Disabled while a core database can't be decrypted."
                        : nil
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
        disabledHelp: String?,
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
                disabledHelp: disabledHelp,
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
        disabledHelp: String?,
        action: @escaping () -> Void
    ) -> some View {
        let button = Button(action: action) {
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

        if let disabledHelp, isDisabled {
            button.help(Text(LocalizedStringKey(disabledHelp), bundle: .module))
        } else {
            button
        }
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
        lastOutcome = await StorageMigrator.shared.loadLastOutcome()
        keyMismatchTargets = await StorageMigrator.shared.detectKeyMismatch()
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
            panel.title = "Choose backup destination"
            panel.message = "Pick an empty folder; the plaintext export will be written here."
        case .beforeRotate:
            panel.title = "Back up before rotating"
            panel.message =
                "Pick a folder to write the plaintext backup to. We'll re-prompt for rotation after the backup completes."
        }
        guard panel.runModal() == .OK, let dest = panel.url else { return }

        let backupDir = dest.appendingPathComponent("osaurus-plaintext-backup", isDirectory: true)
        isWorking = true
        errorMessage = nil
        Task {
            do {
                let summary = try await StorageExportService.shared.exportPlaintextBackup(to: backupDir)
                await MainActor.run {
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

    private func cleanupOrphans() {
        let toRemove = pluginMismatchTargets
        isWorking = true
        errorMessage = nil
        Task {
            let summary = await StorageExportService.shared.cleanupOrphanedPluginDatabases(
                targets: toRemove
            )
            await MainActor.run {
                self.isWorking = false
                self.lastSummary =
                    "Removed \(summary.directoriesRemoved) orphaned plugin director\(summary.directoriesRemoved == 1 ? "y" : "ies")."
            }
            await refresh()
        }
    }
}
