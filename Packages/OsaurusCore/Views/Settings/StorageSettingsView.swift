//
//  StorageSettingsView.swift
//  osaurus
//
//  Settings panel for everything disk-related: where models live (models
//  directory + external model sources) and how local data is protected at
//  rest. Osaurus stores local data **plaintext by default** (relying on
//  FileVault) for reliability, and lets users opt in to SQLCipher encryption
//  here. The panel reflects the *actual* on-disk state, exposes the opt-in
//  toggle (which runs a live migration), and keeps the plaintext-backup /
//  key-rotation admin actions.
//
//  Surfaced by the WhatsNew page action `openStorageSettings` and reachable
//  from the management settings sidebar.
//

import AppKit
import SwiftUI

public struct StorageSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var posture: StorageOnDiskPosture = .empty
    @State private var desiredEncrypted: Bool = false
    @State private var keyPresent: Bool = false
    @State private var fileVaultOn: Bool = false

    @State private var storeIssues: [StorageStoreIssue] = []
    @State private var recoveringStore: String?
    @State private var pendingResetStore: StorageRecoveryService.Store?
    @State private var showStoreResetConfirm: Bool = false

    @State private var lastSummary: String = ""
    @State private var isWorking: Bool = false
    @State private var workingLabel: String = ""
    @State private var errorMessage: String?

    @State private var showEnableConfirm: Bool = false
    @State private var showRotateConfirm: Bool = false
    @State private var hasExportedBackupThisSession: Bool = false
    @State private var showTechnicalDetails: Bool = false

    @State private var hasAppeared = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            headerView
                .managerHeaderEntrance(hasAppeared: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    modelStorageSection
                    externalModelsSection
                    postureCard
                        .settingsLandingAnchor("storage.encryption")
                    if !storeIssues.isEmpty {
                        recoveryCard
                    }
                    tradeoffsCard
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
        .alert("Encrypt local data at rest?", isPresented: $showEnableConfirm) {
            Button(localized: "Cancel", role: .cancel) {}
            Button(localized: "Enable encryption") { applyEncryption(true) }
        } message: {
            Text(
                "Osaurus will re-encrypt your databases and attachments with SQLCipher using a key stored in your macOS Keychain. If that key is ever lost — wiping the Keychain, re-signing the app, or migrating Macs without iCloud Keychain — the encrypted data becomes unrecoverable. Keep a plaintext backup if you rely on this data.",
                bundle: .module
            )
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
        .alert(
            "Reset this store?",
            isPresented: $showStoreResetConfirm,
            presenting: pendingResetStore
        ) { store in
            Button(localized: "Cancel", role: .cancel) {}
            Button(localized: "Reset", role: .destructive) { resetStore(store) }
        } message: { store in
            Text(
                "\(store.displayName) is moved to ~/.osaurus/quarantine/ (never deleted) and recreated empty so the feature works again. Data in the old file stays in quarantine — keep a plaintext backup if you might recover the key.",
                bundle: .module
            )
        }
    }

    // MARK: - Header

    private var headerView: some View {
        ManagerHeader(
            title: L("Storage"),
            subtitle: L("Where Osaurus stores data on disk — and how it's protected")
        )
    }

    // MARK: - Model storage (relocated from the General tab)

    /// Where downloaded models live on disk.
    private var modelStorageSection: some View {
        SettingsSection(title: "Models Directory", icon: "cube.box", anchorId: "storage.location") {
            DirectoryPickerView()
        }
    }

    /// External model sources (HF cache, LM Studio) discovered in place.
    private var externalModelsSection: some View {
        SettingsSection(
            title: "External Models",
            icon: "square.stack.3d.up",
            anchorId: "storage.externalModels"
        ) {
            ExternalModelsSettingsView()
        }
    }

    // MARK: - Posture + toggle

    private var postureCard: some View {
        SettingsSection(title: "Encryption", icon: "lock.shield") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: postureIcon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(postureColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(LocalizedStringKey(postureTitle), bundle: .module)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text(LocalizedStringKey(postureSubtitle), bundle: .module)
                            .font(.system(size: 12))
                            .foregroundColor(theme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                Divider().background(theme.primaryBorder.opacity(0.2))

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Encrypt local data at rest (SQLCipher)", bundle: .module)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                        Text(
                            "Turning this on or off migrates every database and attachment to the new format.",
                            bundle: .module
                        )
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if isWorking {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.6)
                            Text(LocalizedStringKey(workingLabel), bundle: .module)
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                        }
                    } else {
                        Toggle("", isOn: encryptionBinding)
                            .toggleStyle(SwitchToggleStyle(tint: theme.accentColor))
                            .labelsHidden()
                    }
                }

                if let err = errorMessage {
                    statusLine(text: err, color: theme.errorColor, icon: "exclamationmark.triangle")
                }
                if !lastSummary.isEmpty {
                    statusLine(text: lastSummary, color: theme.successColor, icon: "checkmark.circle")
                }
            }
        }
    }

    // MARK: - Trade-offs

    private var tradeoffsCard: some View {
        SettingsSection(title: "Why Encryption Is Opt-In", icon: "scalemass") {
            VStack(alignment: .leading, spacing: 8) {
                fileVaultRow
                aboutRow(
                    icon: "externaldrive.fill.badge.checkmark",
                    text:
                        "On modern Macs, FileVault already encrypts your whole disk at rest. Plaintext storage relies on that, and is the most reliable option — it never depends on a Keychain key."
                )
                aboutRow(
                    icon: "lock.fill",
                    text:
                        "SQLCipher adds a second layer: databases and attachments are encrypted with a 256-bit key in your Keychain. Useful if you share the Mac account or don't use FileVault."
                )
                aboutRow(
                    icon: "exclamationmark.triangle.fill",
                    text:
                        "The trade-off is reliability: if the Keychain key is lost (Keychain wipe, app re-sign, or Mac migration without iCloud Keychain), encrypted data can't be opened. Plaintext data is never at that risk."
                )
                aboutRow(
                    icon: "magnifyingglass",
                    text:
                        "Either way, full-text search and all features work the same; encryption only changes how bytes sit on disk."
                )
            }
        }
    }

    /// Concrete FileVault status so the plaintext recommendation reflects the
    /// machine's real at-rest protection: green/reassuring when on, an amber
    /// caution when off (since plaintext then has no disk encryption behind it,
    /// and it's also why an existing encrypted install was kept encrypted).
    private var fileVaultRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: fileVaultOn ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(fileVaultOn ? theme.successColor : theme.warningColor)
                .frame(width: 16, alignment: .center)
                .padding(.top, 2)
            Text(
                LocalizedStringKey(
                    fileVaultOn
                        ? "FileVault is on — your disk is already encrypted at rest, so plaintext storage stays protected and is the most reliable choice."
                        : "FileVault is off — plaintext storage would not be encrypted at rest. Keep SQLCipher on, or turn on FileVault in System Settings → Privacy & Security."
                ),
                bundle: .module
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(fileVaultOn ? theme.successColor : theme.warningColor)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Per-store recovery

    /// Shown only when one or more stores failed to open this session.
    /// Lists the real cause per store and offers Retry / Reset so a lost
    /// key (or corruption) never leaves the user with a silently dead
    /// subsystem and no way forward.
    private var recoveryCard: some View {
        SettingsSection(title: "Stores Needing Attention", icon: "exclamationmark.triangle.fill") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(sortedStoreIssues, id: \.store) { issue in
                    storeIssueRow(issue)
                    if issue.store != sortedStoreIssues.last?.store {
                        Divider().background(theme.primaryBorder.opacity(0.2))
                    }
                }
            }
        }
    }

    private var sortedStoreIssues: [StorageStoreIssue] {
        storeIssues.sorted { $0.store < $1.store }
    }

    @ViewBuilder
    private func storeIssueRow(_ issue: StorageStoreIssue) -> some View {
        let store = StorageRecoveryService.Store(rawValue: issue.store)
        let label = store?.displayName ?? issue.store
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(LocalizedStringKey(label), bundle: .module)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Text(LocalizedStringKey(issueKindBadge(issue.kind)), bundle: .module)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(issueKindColor(issue.kind)))
                Spacer(minLength: 8)
                if recoveringStore == issue.store {
                    ProgressView().scaleEffect(0.55)
                } else if store != nil {
                    HStack(spacing: 6) {
                        actionButton(
                            icon: "arrow.clockwise",
                            label: "Retry",
                            isPrimary: false,
                            isDisabled: recoveringStore != nil
                        ) { retryStore(store!) }
                        actionButton(
                            icon: "trash",
                            label: "Reset…",
                            isPrimary: false,
                            isDisabled: recoveringStore != nil
                        ) {
                            pendingResetStore = store
                            showStoreResetConfirm = true
                        }
                    }
                }
            }
            Text(LocalizedStringKey(issueKindCause(issue.kind)), bundle: .module)
                .font(.system(size: 11))
                .foregroundColor(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func issueKindBadge(_ kind: StorageOpenIssueKind) -> String {
        switch kind {
        case .locked: return "LOCKED"
        case .corrupt: return "CORRUPT"
        case .migration: return "MIGRATION"
        case .unknown: return "ERROR"
        }
    }

    private func issueKindColor(_ kind: StorageOpenIssueKind) -> Color {
        switch kind {
        case .locked: return theme.warningColor
        case .corrupt: return theme.errorColor
        case .migration: return theme.errorColor
        case .unknown: return theme.secondaryText
        }
    }

    private func issueKindCause(_ kind: StorageOpenIssueKind) -> String {
        switch kind {
        case .locked:
            return
                "Encrypted, but the storage key is unavailable on this Mac. Restore the Keychain key and Retry, or Reset to start fresh."
        case .corrupt:
            return
                "The file isn't a readable database (corruption or a key mismatch). Reset to recreate it; the original is quarantined."
        case .migration:
            return "A schema migration failed. Retry after updating, or Reset to recreate the store."
        case .unknown:
            return "The store failed to open for an unrecognized reason. Retry, or Reset if it persists."
        }
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

    // MARK: - Actions

    private var actionsCard: some View {
        SettingsSection(title: "Backup & Key", icon: "archivebox") {
            VStack(alignment: .leading, spacing: 12) {
                actionRow(
                    icon: "square.and.arrow.up",
                    title: "Export plaintext backup…",
                    buttonLabel: "Export…",
                    subtitle:
                        "Writes a plaintext copy of every database, attachment, and config under ~/.osaurus to a folder you choose. Recommended before reinstalling macOS or moving Macs.",
                    isPrimary: true,
                    isDisabled: isWorking
                ) {
                    runExport(reason: .userInitiated)
                }

                if desiredEncrypted {
                    Divider().background(theme.primaryBorder.opacity(0.2))

                    actionRow(
                        icon: "key.fill",
                        title: "Rotate storage key",
                        buttonLabel: "Rotate",
                        subtitle:
                            "Generate a new 256-bit key and re-encrypt every artifact. The old key is destroyed. Only available while encryption is on.",
                        isPrimary: false,
                        isDisabled: isWorking
                    ) {
                        showRotateConfirm = true
                    }
                }

                if desiredEncrypted {
                    Divider().background(theme.primaryBorder.opacity(0.2))
                    technicalDetails
                }
            }
        }
    }

    private var technicalDetails: some View {
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
                Text(
                    keyPresent ? "Keychain key: present" : "Keychain key: not found",
                    bundle: .module
                )
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
            "When encryption is on, wiping the macOS Keychain or migrating to a new Mac without iCloud Keychain sync makes encrypted storage unrecoverable. Export a plaintext backup before migrating.",
            bundle: .module
        )
        .font(.system(size: 11))
        .foregroundColor(theme.secondaryText.opacity(0.85))
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Derived state

    private var rotateAlertMessage: String {
        if hasExportedBackupThisSession {
            return
                L(
                    "A new 256-bit key will be generated and every encrypted database + file under ~/.osaurus will be re-encrypted against it. The old key is destroyed — backups made under the old key will no longer be readable on this Mac."
                )
        }
        return
            L(
                "A new 256-bit key will be generated and every encrypted database + file under ~/.osaurus will be re-encrypted against it. The old key is destroyed — backups made under the old key will no longer be readable on this Mac. We strongly recommend exporting a plaintext backup first."
            )
    }

    private var postureTitle: String {
        switch posture {
        case .empty: return L("No local data yet")
        case .plaintext: return L("Stored as plaintext")
        case .encrypted: return L("Encrypted with SQLCipher")
        case .mixed: return L("Migration in progress")
        }
    }

    private var postureSubtitle: String {
        switch posture {
        case .empty:
            return desiredEncrypted
                ? L("New data will be encrypted with SQLCipher.")
                : L("New data will be stored as plaintext, protected by FileVault.")
        case .plaintext:
            return L("Your databases are not encrypted by Osaurus. macOS FileVault protects them at rest.")
        case .encrypted:
            return L("Your databases are encrypted with a 256-bit key in your macOS Keychain.")
        case .mixed:
            return L("Some stores are still converting. Reopen this panel in a moment to confirm.")
        }
    }

    private var postureIcon: String {
        switch posture {
        case .empty: return "tray"
        case .plaintext: return "externaldrive"
        case .encrypted: return "lock.shield.fill"
        case .mixed: return "arrow.triangle.2.circlepath"
        }
    }

    private var postureColor: Color {
        switch posture {
        case .empty: return theme.secondaryText
        case .plaintext: return theme.accentColor
        case .encrypted: return theme.successColor
        case .mixed: return theme.warningColor
        }
    }

    private var encryptionBinding: Binding<Bool> {
        Binding(
            get: { desiredEncrypted },
            set: { newValue in
                if newValue {
                    // Enabling adds the key-loss risk — confirm first. The
                    // toggle stays visually off until `applyEncryption` lands.
                    showEnableConfirm = true
                } else {
                    applyEncryption(false)
                }
            }
        )
    }

    // MARK: - Actions

    private func refresh() async {
        let snapshot = await Task.detached(priority: .userInitiated) {
            (
                StorageMigrationCoordinator.detectOnDiskPosture(),
                StorageEncryptionPolicy.shared.isEncryptionEnabled,
                StorageKeyManager.shared.keyExists(),
                PersistenceHealth.shared.storeIssues(),
                FileVaultStatus.isEnabled()
            )
        }.value
        posture = snapshot.0
        desiredEncrypted = snapshot.1
        keyPresent = snapshot.2
        storeIssues = snapshot.3
        fileVaultOn = snapshot.4
    }

    private func retryStore(_ store: StorageRecoveryService.Store) {
        guard recoveringStore == nil else { return }
        recoveringStore = store.rawValue
        errorMessage = nil
        Task {
            let ok = await StorageRecoveryService.shared.retryStore(store)
            await MainActor.run {
                self.recoveringStore = nil
                if ok {
                    self.lastSummary = String(
                        format: L("%@ reopened."),
                        store.displayName
                    )
                } else {
                    self.errorMessage = String(
                        format: L("%@ still can't be opened. Try Reset."),
                        store.displayName
                    )
                }
            }
            await refresh()
        }
    }

    private func resetStore(_ store: StorageRecoveryService.Store) {
        guard recoveringStore == nil else { return }
        recoveringStore = store.rawValue
        errorMessage = nil
        Task {
            let dest = await StorageRecoveryService.shared.resetStore(store)
            await MainActor.run {
                self.recoveringStore = nil
                if let dest {
                    self.lastSummary = String(
                        format: L("%@ reset. Old file kept at %@."),
                        store.displayName,
                        dest.lastPathComponent
                    )
                } else {
                    self.lastSummary = String(format: L("%@ reset."), store.displayName)
                }
            }
            await refresh()
        }
    }

    private func applyEncryption(_ enabled: Bool) {
        isWorking = true
        workingLabel = enabled ? "Encrypting…" : "Decrypting…"
        errorMessage = nil
        lastSummary = ""
        Task {
            do {
                let report = try await StorageMigrationCoordinator.shared.setEncryptionEnabled(enabled)
                await MainActor.run {
                    self.isWorking = false
                    self.desiredEncrypted = enabled
                    if !report.locked.isEmpty {
                        self.errorMessage = String(
                            format: L(
                                "%lld store(s) couldn't be converted because the encryption key is unavailable."
                            ),
                            report.locked.count
                        )
                    } else if !report.failed.isEmpty {
                        self.errorMessage = String(
                            format: L("%lld store(s) failed to convert."),
                            report.failed.count
                        )
                    } else if enabled {
                        self.lastSummary = String(
                            format: L("Encrypted %lld store(s) at rest."),
                            report.converted
                        )
                    } else {
                        self.lastSummary = String(
                            format: L("Decrypted %lld store(s); now plaintext at rest."),
                            report.converted
                        )
                    }
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

    /// Why an export is being run — drives the open-panel copy, the success
    /// summary line, and what happens after success (reveal in Finder vs.
    /// re-present the rotate confirmation).
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
            workingLabel = "Exporting…"
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
        workingLabel = "Rotating…"
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
