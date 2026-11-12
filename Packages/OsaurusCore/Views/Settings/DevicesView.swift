//
//  DevicesView.swift
//  osaurus
//
//  Sharing → Devices: the user's own Macs and iPhones in one sync account.
//  Whether chats sync and how devices find each other, whether this Mac
//  runs agents for the others (what the iPhone needs), one device list,
//  one Add a Device flow for a Mac or an iPhone, the iPhone's keep-awake and
//  handoff, the recovery phrase, storage, a support report, and sign-out.
//

import AppKit
import OsaurusSync
import SwiftUI
import UniformTypeIdentifiers

struct DevicesView: View {
    /// The iPhone app's TestFlight, offered next to the pairing code.
    static let iPhoneAppURL = URL(string: "https://testflight.apple.com/join/yTF86bVb")!

    @Environment(\.theme) private var theme
    @ObservedObject private var model = SyncStatusModel.shared
    @ObservedObject private var importer = SyncLegacyImporter.shared
    @ObservedObject private var phones = SyncPhoneDevices.shared
    @AppStorage(SyncPhoneDevices.keepAwakeDefaultsKey) private var keepMacAwake = true
    @AppStorage(PhoneChatHandoff.defaultsKey) private var continuePhoneChats = true

    @State private var joinLink = ""
    @State private var isJoining = false
    @State private var phrase: [String]?
    @State private var restoreText = ""
    @State private var isRestoring = false
    @State private var isSigningOut = false
    @State private var actionError: String?

    private static let qrSide: CGFloat = 136

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Devices",
                subtitle: "Your Macs and iPhones in one end-to-end encrypted account, with no account to create"
            )
        } content: {
            notices
            syncSection
            devicesSection
            addDeviceSection
            iPhoneSection
            recoverySection
            storageSection
            supportSection
            signOutSection
        }
        .onAppear {
            model.start()
            model.beginWatching()
        }
        .onDisappear { model.endWatching() }
        .onChange(of: keepMacAwake) { _, _ in phones.refreshKeepAwake() }
    }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        if let error = model.openError {
            SettingsCallout(icon: "exclamationmark.triangle.fill", title: "Sync Isn't Running", message: error, tone: .error) {
                SettingsButton(.secondary, "Try again") { model.retryOpen() }
            }
        }
        if model.revoked {
            SettingsCallout(
                icon: "iphone.slash",
                title: "This Mac Was Removed",
                message: "Its chats stay here, but they no longer sync. Sign out below to pair this Mac again.",
                tone: .warning
            )
        }
        if model.recoveryAvailable {
            if model.configuration.walletLinked {
                SettingsCallout(
                    icon: "key.horizontal.fill",
                    title: "Unlock Your Chats",
                    message: "This Mac's sync keys are gone. Your Osaurus recovery phrase restores sync, so it can unlock these chats.",
                    tone: .info
                ) {
                    HStack(spacing: theme.space.s8) {
                        if OsaurusIdentity.existsCached() {
                            SettingsButton(.primary, "Unlock With My Osaurus Recovery Phrase") { useWalletPhrase() }
                        }
                        SettingsButton(.secondary, "Enter phrase") { isRestoring = true }
                    }
                }
            } else {
                SettingsCallout(
                    icon: "key.horizontal.fill",
                    title: "Enter Your Recovery Phrase",
                    message: "This Mac was restored from a backup. Enter the recovery phrase of the account it came from to read its chats.",
                    tone: .info
                ) {
                    SettingsButton(.secondary, "Enter phrase") { isRestoring = true }
                }
            }
        }
        if let actionError {
            SettingsCallout(icon: "exclamationmark.circle.fill", title: "That Didn't Work", message: actionError, tone: .error) {
                SettingsButton(.tertiary, "Dismiss") { self.actionError = nil }
            }
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        SettingsSection(title: "Sync") {
            SettingsToggle(
                title: "Sync Chats",
                description: "Send and receive chats with your other devices. When off, chats stay on this Mac until you turn it back on.",
                anchorId: "settings.sync.network",
                isOn: Binding(get: { model.configuration.networkEnabled }, set: { model.setNetworkEnabled($0) })
            )
            SettingsPickerRow(
                title: "Find Devices",
                description: "Same Network reaches devices on your Wi-Fi or Ethernet. Anywhere also connects through Osaurus servers, so your devices sync on different networks. Chats stay end-to-end encrypted either way.",
                anchorId: "settings.sync.networkMode",
                selection: Binding(get: { model.configuration.networkMode }, set: { model.setNetworkMode($0) }),
                options: [
                    .init(.localNetworkOnly, "Same Network"),
                    .init(.anywhere, "Anywhere (Beta)"),
                ]
            )
            .disabled(!model.configuration.networkEnabled)
            SettingsToggle(
                title: "Run Agents for My Other Devices",
                description: "Your other devices, your iPhone included, can chat with this Mac's agents. The agents run here, with this Mac's models, tools and files, and ask before using tools on the device you're chatting on. Your iPhone needs this on.",
                anchorId: "settings.sync.hostAgents",
                isOn: Binding(
                    get: { model.configuration.hostAgentsForOtherDevices },
                    set: { model.setHostAgentsForOtherDevices($0) }
                )
            )
            SettingsValueRow(
                title: "Status",
                value: statusText,
                dot: statusDot,
                anchorId: "settings.sync.status"
            )
            if model.pendingMessages > 0 {
                SettingsValueRow(
                    title: "Waiting to Send",
                    value: String(format: L("%lld messages"), model.pendingMessages)
                )
            }
            if model.configuration.networkMode == .anywhere, model.configuration.networkEnabled {
                SettingsValueRow(
                    title: "Osaurus Servers",
                    value: model.relays.contains(where: \.connected) ? L("Connected") : L("Not connected")
                )
            }
            importRow
        }
    }

    private var statusText: String {
        if !model.isOpen { return L("Not running") }
        if !model.configuration.networkEnabled { return L("Off") }
        if model.otherDeviceCount == 0 { return L("No other devices yet") }
        if model.connectedDeviceCount > 0 {
            return String(format: L("Connected to %lld of %lld devices"), model.connectedDeviceCount, model.otherDeviceCount)
        }
        return L("Waiting for your other devices")
    }

    private var statusDot: Color {
        if !model.isOpen { return theme.status.error.foreground }
        if !model.configuration.networkEnabled || model.otherDeviceCount == 0 { return theme.text.tertiary }
        return model.connectedDeviceCount > 0 ? theme.status.success.foreground : theme.status.warning.foreground
    }

    @ViewBuilder
    private var importRow: some View {
        switch importer.state {
        case .idle:
            EmptyView()
        case let .importing(done, total):
            SettingsRow(
                title: "Earlier Chats",
                description: String(format: L("Copying chats from before sync: %lld of %lld"), done, total),
                verbatimDescription: true
            ) {
                SettingsProgressBar(value: total > 0 ? Double(done) / Double(total) : 0)
                    .frame(maxWidth: 160)
            }
        case let .finished(_, failed) where failed > 0:
            SettingsValueRow(
                title: "Earlier Chats",
                value: String(format: L("%lld couldn't be copied. Osaurus tries again next launch."), failed)
            )
        case .finished:
            EmptyView()
        }
    }

    // MARK: - Devices

    private var devicesSection: some View {
        SettingsSection(title: "Devices", anchorId: "settings.sync.devices") {
            ForEach(model.devices, id: \.id) { device in
                deviceRow(device)
            }
        }
    }

    private var addDeviceSection: some View {
        SettingsSection(title: "Add a Device") {
            SettingsRow(
                title: "Add a Device",
                description: "Show a code on this Mac, then scan it with the Osaurus app on your iPhone, or paste its link on another Mac.",
                anchorId: "settings.sync.addDevice"
            ) {
                if case .offering = model.pairing {
                    SettingsButton(.tertiary, "Cancel") { model.cancelPairing() }
                } else {
                    SettingsButton(.secondary, "Show Code") { model.startPairing() }
                        .disabled(!model.isOpen)
                }
            }
            if case let .offering(offer) = model.pairing {
                pairingPanel(offer)
            }
            SettingsLinkRow(
                title: "Osaurus for iPhone",
                description: "Get the iPhone app from TestFlight, then add your iPhone with the code above.",
                actionTitle: "Get the App",
                anchorId: "settings.devices.iPhoneApp"
            ) {
                NSWorkspace.shared.open(Self.iPhoneAppURL)
            }
            SettingsRow(
                title: "Join Another Device",
                description: "Paste the pairing link from a device that already syncs. This Mac's chats join that device's account.",
                anchorId: "settings.sync.join"
            ) {
                if model.pairing == .joining {
                    SettingsSpinner()
                } else {
                    SettingsButton(.secondary, isJoining ? "Cancel" : "Join…") {
                        isJoining.toggle()
                        joinLink = ""
                        model.dismissPairingResult()
                    }
                    .disabled(!model.isOpen)
                }
            }
            if isJoining, model.pairing != .joining {
                HStack(spacing: theme.space.s8) {
                    SettingsTextField(placeholder: "osaurus-pair:…", text: $joinLink, monospaced: true, onSubmit: join)
                    SettingsButton(.primary, "Join", action: join)
                        .disabled(joinLink.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            pairingResult
        }
    }

    private func join() {
        model.join(link: joinLink)
        isJoining = false
    }

    // MARK: - iPhone

    private var iPhoneSection: some View {
        SettingsSection(title: "iPhone") {
            SettingsToggle(
                title: "Keep Mac Awake for iPhone",
                description: "While an iPhone is in your devices, this Mac doesn't go to sleep on its own, so your agents stay reachable. The display may still sleep, and closing a MacBook lid or choosing Sleep always wins.",
                anchorId: "settings.devices.keepAwake",
                isOn: $keepMacAwake
            )
            SettingsToggle(
                title: "Continue iPhone Chats on This Mac",
                description: "When you come back to this Mac after this Mac answered a chat from your iPhone, that chat opens in front.",
                anchorId: "settings.devices.continuePhoneChats",
                isOn: $continuePhoneChats
            )
            ManagementChildLinkRows(parent: .devices)
            if !phones.hasPhone {
                SettingsValueRow(title: "Your iPhone", value: L("Not added yet"))
            } else if !model.configuration.hostAgentsForOtherDevices {
                SettingsCallout(
                    icon: "exclamationmark.triangle.fill",
                    title: "Your iPhone Can't Use This Mac's Agents",
                    message: "Turn on Run Agents for My Other Devices above so your iPhone can chat with them.",
                    tone: .warning
                )
            }
        }
    }

    private func deviceRow(_ device: Device) -> some View {
        SettingsRow(
            title: device.name,
            description: deviceDetail(device),
            verbatimTitle: true,
            verbatimDescription: true,
            leading: { SettingsIconTile(icon: device.devicePlatform.symbol) }
        ) {
            HStack(spacing: theme.space.s8) {
                if !device.isSelf, !device.revoked, model.isConnected(device) {
                    StatusChip(L("Connected"), tone: .success, showsDot: true)
                }
                if device.revoked {
                    StatusChip(L("Removed"), tone: .neutral)
                }
                if !device.isSelf, !device.revoked {
                    SettingsOverflowMenu(help: "Device actions") {
                        Button(L("Remove Device…")) { confirmRevoke(device, rotate: false) }
                        Button(L("Remove and Change Recovery Phrase…")) { confirmRevoke(device, rotate: true) }
                    }
                }
            }
        }
    }

    private func deviceDetail(_ device: Device) -> String {
        if device.isSelf { return L("This Mac") }
        let kind = device.devicePlatform.kindLabel
        if device.revoked { return String(format: L("%@ · No longer syncs"), kind) }
        if model.isConnected(device) { return String(format: L("%@ · Connected now"), kind) }
        guard let ms = device.lastSeenMs else { return String(format: L("%@ · Not seen yet"), kind) }
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        let relative = RelativeDateTimeFormatter().localizedString(for: date, relativeTo: Date())
        return String(format: L("%@ · Last seen %@"), kind, relative)
    }

    private func pairingPanel(_ offer: PairingOffer) -> some View {
        HStack(alignment: .top, spacing: theme.space.s16) {
            ShareQRCardView(text: offer.payload)
                .frame(width: Self.qrSide, height: Self.qrSide)
            VStack(alignment: .leading, spacing: theme.space.s12) {
                VStack(alignment: .leading, spacing: theme.space.s4) {
                    Text("Code", bundle: .module)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.tertiary)
                    Text(verbatim: Self.grouped(offer.code))
                        .font(SettingsFont.detailTitle)
                        .monospaced()
                        .foregroundColor(theme.text.primary)
                        .textSelection(.enabled)
                }
                ShareCopyRow(label: L("Pairing link, for another Mac"), value: offer.payload)
                Text("Scan the code with the Osaurus app on your iPhone, or paste the link into Join Another Device on another Mac. It works for 5 minutes.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The core may already group the code with dashes; regroup the bare characters.
    private static func grouped(_ code: String) -> String {
        let code = code.filter { $0.isLetter || $0.isNumber }
        return stride(from: 0, to: code.count, by: 4).map { start in
            let lower = code.index(code.startIndex, offsetBy: start)
            let upper = code.index(lower, offsetBy: 4, limitedBy: code.endIndex) ?? code.endIndex
            return String(code[lower..<upper])
        }.joined(separator: " ")
    }

    @ViewBuilder
    private var pairingResult: some View {
        switch model.pairing {
        case let .paired(name):
            SettingsCallout(
                icon: "checkmark.circle.fill",
                title: "Device Added",
                message: String(format: L("Your chats now sync with %@."), name),
                tone: .success
            ) {
                SettingsButton(.tertiary, "Done") { model.dismissPairingResult() }
            }
        case let .failed(message):
            SettingsCallout(icon: "exclamationmark.circle.fill", title: "Pairing Didn't Finish", message: message, tone: .error) {
                SettingsButton(.tertiary, "Dismiss") { model.dismissPairingResult() }
            }
        default:
            EmptyView()
        }
    }

    // MARK: - Recovery

    private var recoverySection: some View {
        SettingsSection(title: "Recovery") {
            if model.configuration.walletLinked {
                SettingsRow(
                    title: "Recovery Phrase",
                    description: "Your Osaurus recovery phrase restores sync. View it in Osaurus ID → Master Address.",
                    anchorId: "settings.sync.recoveryPhrase"
                ) {
                    EmptyView()
                }
            } else {
                SettingsRow(
                    title: "Recovery Phrase",
                    description: "24 words that bring your chats back if you lose every device. Write them down and keep them somewhere safe.",
                    anchorId: "settings.sync.recoveryPhrase"
                ) {
                    SettingsButton(.secondary, phrase == nil ? "Show" : "Hide") { togglePhrase() }
                        .disabled(!model.isOpen)
                }
                if let phrase {
                    phraseGrid(phrase)
                }
                if OsaurusIdentity.existsCached() {
                    SettingsRow(
                        title: "Use My Osaurus Recovery Phrase",
                        description: "Keep one phrase instead of two: your Osaurus recovery phrase will restore sync too. This Mac keeps its chats.",
                        anchorId: "settings.sync.useWalletPhrase"
                    ) {
                        SettingsButton(.secondary, "Use…") { confirmUseWalletPhrase() }
                            .disabled(!model.isOpen)
                    }
                }
            }
            SettingsRow(
                title: "Restore From Phrase",
                description: "Enter a recovery phrase to read that account's chats on this Mac. This Mac's own chats move to that account.",
                anchorId: "settings.sync.restorePhrase"
            ) {
                SettingsButton(.secondary, isRestoring ? "Cancel" : "Restore…") {
                    isRestoring.toggle()
                    restoreText = ""
                }
                .disabled(!model.isOpen)
            }
            if isRestoring {
                VStack(alignment: .trailing, spacing: theme.space.s8) {
                    SettingsTextField(
                        placeholder: "Enter the 24 words, separated by spaces",
                        text: $restoreText,
                        axis: .vertical,
                        lineLimit: 3,
                        monospaced: true
                    )
                    SettingsButton(.primary, "Restore") { confirmRestore() }
                        .disabled(restoreText.split(whereSeparator: \.isWhitespace).count < 12)
                }
            }
        }
    }

    private func phraseGrid(_ words: [String]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), spacing: theme.space.s8) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack(spacing: theme.space.s6) {
                    Text(verbatim: "\(index + 1).")
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.tertiary)
                    Text(verbatim: word)
                        .font(SettingsFont.monoSmall)
                        .foregroundColor(theme.text.primary)
                }
            }
        }
        .textSelection(.enabled)
        .padding(theme.space.s12)
        .settingsChrome(.inset)
    }

    private func togglePhrase() {
        if phrase != nil {
            phrase = nil
            return
        }
        do {
            phrase = try model.recoveryPhrase()
        } catch {
            actionError = error.syncUserMessage
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        SettingsSection(title: "Storage", anchorId: "settings.sync.storage") {
            if let usage = model.storage {
                SettingsValueRow(title: "Synced Chats", value: Self.bytes(usage.syncedEventBytes))
                SettingsValueRow(title: "This Mac Only", value: Self.bytes(usage.localEventBytes))
                SettingsValueRow(title: "Attachments", value: Self.bytes(usage.attachmentBytes))
                SettingsValueRow(
                    title: "Total on Disk",
                    value: Self.bytes(usage.databaseBytes + usage.attachmentBytes + usage.attachmentCacheBytes)
                )
            } else {
                SettingsValueRow(title: "Total on Disk", value: "—")
            }
        }
    }

    private static func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }

    // MARK: - Support

    private var supportSection: some View {
        SettingsSection(title: "Support") {
            SettingsRow(
                title: "Support Report",
                description: "Connection details and recent sync logs to send with a bug report. It never includes chat content, titles or keys.",
                anchorId: "settings.sync.supportReport"
            ) {
                SettingsButton(.secondary, "Save…") { saveSupportReport() }
                    .disabled(!model.isOpen)
            }
        }
    }

    private func saveSupportReport() {
        guard let report = model.supportBundle() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "osaurus-sync-report.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(report.utf8).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: - Sign out

    private var signOutSection: some View {
        SettingsDestructiveZone(title: "Sign Out") {
            SettingsDestructiveRow(
                title: "Sign Out and Keep Chats",
                description: "This Mac stops syncing. Its chats stay here, on this Mac only, and you can pair it again later.",
                actionTitle: "Sign Out…",
                severity: .warning,
                anchorId: "settings.sync.signOutKeep"
            ) {
                confirmSignOut(keepConversations: true)
            }
            .disabled(!model.isOpen || isSigningOut)
            SettingsDestructiveRow(
                title: "Sign Out and Remove Chats",
                description: "Deletes this Mac's copy of every chat and its sync keys. Your other devices keep theirs.",
                actionTitle: "Remove…",
                anchorId: "settings.sync.signOutRemove"
            ) {
                confirmSignOut(keepConversations: false)
            }
            .disabled(!model.isOpen || isSigningOut)
        }
    }

    // MARK: - Confirmations

    private func confirm(_ title: String, _ message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: L("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmRevoke(_ device: Device, rotate: Bool) {
        let title = String(format: L("Remove %@?"), device.name)
        let message =
            rotate
            ? (model.configuration.walletLinked
                ? L("Use this for a lost or stolen device. Your account gets new keys and its own recovery phrase again, since anyone holding your Osaurus recovery phrase could derive the old one; your other devices pick them up the next time they connect.")
                : L("Use this for a lost or stolen device. Your account gets new keys and a new recovery phrase; your other devices pick them up the next time they connect. The old phrase stops working."))
            : device.devicePlatform == .iPhone
                ? L("Use this for an iPhone you've wiped or given away. It stops receiving your chats and can't allow tools or change agents on this Mac. If it was lost or stolen, use Remove and Change Recovery Phrase instead.")
                : L("Use this for a device you've wiped or given away. It stops receiving your chats.")
        guard confirm(title, message, action: L("Remove")) else { return }
        do {
            if rotate {
                phrase = try model.revokeAndRotate(device)
            } else {
                try model.revoke(device)
            }
        } catch {
            actionError = error.syncUserMessage
        }
    }

    private func confirmRestore() {
        guard
            confirm(
                L("Restore from this phrase?"),
                L("This Mac joins the account the phrase belongs to, and its own chats move to that account."),
                action: L("Restore")
            )
        else { return }
        do {
            try model.recover(phrase: restoreText)
            isRestoring = false
            restoreText = ""
            phrase = nil
        } catch {
            actionError = error.syncUserMessage
        }
    }

    private func confirmUseWalletPhrase() {
        let message =
            model.otherDeviceCount > 0
            ? L("This Mac's sync account changes to the one your Osaurus recovery phrase restores, and it keeps its chats. Your other devices stop syncing with this Mac until you do the same on each of them.")
            : L("This Mac's sync account changes to the one your Osaurus recovery phrase restores, and it keeps its chats. Your current sync phrase stops working.")
        guard confirm(L("Use your Osaurus recovery phrase for sync?"), message, action: L("Use Phrase")) else { return }
        useWalletPhrase()
    }

    private func useWalletPhrase() {
        do {
            try SyncWalletLink.useWalletPhrase()
            phrase = nil
            isRestoring = false
            model.refresh()
        } catch {
            actionError = error.syncUserMessage
        }
    }

    private func confirmSignOut(keepConversations: Bool) {
        let confirmed =
            keepConversations
            ? confirm(
                L("Sign out of sync?"),
                L("This Mac stops syncing and keeps its chats. Your other devices keep theirs."),
                action: L("Sign Out")
            )
            : confirm(
                L("Remove chats from this Mac?"),
                L("Every chat on this Mac and its sync keys are deleted. Chats that weren't synced to another device are lost."),
                action: L("Remove Chats")
            )
        guard confirmed else { return }
        isSigningOut = true
        phrase = nil
        Task {
            defer { isSigningOut = false }
            do {
                try await model.signOut(keepConversations: keepConversations)
            } catch {
                actionError = error.syncUserMessage
            }
        }
    }
}
