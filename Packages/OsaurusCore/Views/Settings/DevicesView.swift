//
//  DevicesView.swift
//  osaurus
//
//  Sharing → Devices: the user's own Macs and iPhones in one sync account.
//  Whether chats sync and how devices find each other, whether this Mac
//  runs agents for the others (what the iPhone needs), the iPhone's
//  keep-awake and handoff, one device list with the iPhone app's link, an
//  Add Device menu in the header (add an iPhone or iPad, or join another
//  device), the recovery phrase, storage, a support report, and sign-out.
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
    @ObservedObject private var legacyPairing = MobilePairingService.shared
    @AppStorage(SyncPhoneDevices.keepAwakeDefaultsKey) private var keepMacAwake = true
    @AppStorage(PhoneChatHandoff.defaultsKey) private var continuePhoneChats = true

    @State private var joinLink = ""
    @State private var isJoining = false
    @State private var phrase: [String]?
    /// Shown at the top after a removal changes the phrase, so it can't go
    /// unnoticed at the bottom of the page.
    @State private var newPhrase: [String]?
    @State private var restoreText = ""
    @State private var isRestoring = false
    @State private var isSigningOut = false
    /// A removal (and its change of phrase) is running: a second can't start until it ends.
    @State private var isRemoving = false
    @State private var actionError: String?
    /// The Add Device menu's sheet: the code an iPhone or iPad scans, or the field for another device's link.
    @State private var pairSheet: PairSheet?
    /// Adding an iPhone or iPad: which way its pairing screen asks, once said.
    @State private var phoneMethod: PhoneMethod = .ask
    /// When the 6-digit way was chosen: a phone paired since then was added by this sheet.
    @State private var codeChosenAt: Date?
    /// The 6-digit pairing is retired once an iPhone joined Sync (`MobileConnectMigration`): only the QR code then.
    @AppStorage(MobileConnectMigration.doneKey) private var legacyPairingRetired = false

    private enum PhoneMethod {
        /// Not said yet: the sheet asks what the phone's pairing screen shows.
        case ask
        /// A QR code to scan: Sync.
        case scan
        /// A 6-digit code to type in: an app without Sync (the Mobile page's pairing).
        case code
    }

    private enum PairSheet: String, Identifiable {
        case addPhone, join
        var id: String { rawValue }
    }

    private static let qrSide: CGFloat = 136

    var body: some View {
        SettingsPage {
            SettingsPageHeader(
                title: "Devices",
                subtitle: "Your Macs and iPhones in one end-to-end encrypted account, with no account to create",
                primary: {
                    SettingsMenuButton(.primary, "Add Device", icon: "plus") {
                        Button(action: addPhone) {
                            Label(L("Add iPhone or iPad"), systemImage: "iphone")
                        }
                        Button(action: startJoining) {
                            Label(L("Join Another Device"), systemImage: "link")
                        }
                    }
                    .disabled(!model.isOpen || model.isConfirmingPairing || model.pairing == .joining)
                    .settingsLandingAnchor("settings.sync.addDevice")
                    .settingsLandingAnchor("settings.sync.join")
                }
            )
        } content: {
            notices
            overviewCard
            syncSection
            devicesSection
            recoverySection
            supportSection
            signOutSection
        }
        .onAppear {
            model.start()
            model.beginWatching()
        }
        .onDisappear {
            model.endWatching()
            phrase = nil
            newPhrase = nil
        }
        .onChange(of: keepMacAwake) { _, _ in phones.refreshKeepAwake() }
        .sheet(item: $pairSheet, onDismiss: endPairing) { kind in pairingSheet(kind) }
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
        if let newPhrase {
            VStack(alignment: .leading, spacing: theme.space.s8) {
                SettingsCallout(
                    icon: "key.horizontal.fill",
                    title: "Write Down Your New Recovery Phrase",
                    message: "Removing the device changed your recovery phrase. The old one no longer works.",
                    tone: .warning
                ) {
                    SettingsButton(.secondary, "I Wrote It Down") { self.newPhrase = nil }
                }
                phraseGrid(newPhrase)
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
        SettingsSection(title: "Settings") {
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
            if phones.hasPhone, !model.configuration.hostAgentsForOtherDevices {
                SettingsCallout(
                    icon: "exclamationmark.triangle.fill",
                    title: "Your iPhone Can't Use This Mac's Agents",
                    message: "Turn on Run Agents for My Other Devices above so your iPhone can chat with them.",
                    tone: .warning
                )
            }
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
            if model.chatsDownloading > 0, model.connectedDeviceCount > 0 {
                SettingsValueRow(
                    title: "Older Messages",
                    value: model.historyPaused
                        ? L("Paused on this network or in Low Power Mode")
                        : String(format: L("Downloading for %lld chats"), model.chatsDownloading)
                )
            }
            if model.suggestAnywhere {
                SettingsCallout(
                    icon: "wifi.exclamationmark",
                    title: "Your Devices Aren't Connecting",
                    message: "Same Network only reaches devices on this Mac's Wi-Fi or Ethernet. If your other devices are somewhere else, use Anywhere (Beta) here and on each of them.",
                    tone: .info
                ) {
                    SettingsButton(.secondary, "Use Anywhere") { model.setNetworkMode(.anywhere) }
                }
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

    /// `statusText` for a narrow card: a word or two.
    private var shortStatusText: String {
        if !model.isOpen { return L("Not running") }
        if !model.configuration.networkEnabled { return L("Off") }
        if model.otherDeviceCount == 0 { return L("No devices") }
        if model.connectedDeviceCount > 0 {
            return String(format: L("%lld of %lld"), model.connectedDeviceCount, model.otherDeviceCount)
        }
        return L("Waiting")
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
        SettingsSection(
            title: "Devices",
            anchorId: "settings.sync.devices",
            accessory: {
                SettingsButton(.tertiary, "Get iOS App", icon: "arrow.up.right", size: .compact) {
                    NSWorkspace.shared.open(Self.iPhoneAppURL)
                }
                .help(L("Get the iPhone and iPad app from TestFlight"))
                .settingsLandingAnchor("settings.devices.iPhoneApp")
            }
        ) {
            ForEach(model.devices, id: \.id) { device in
                deviceRow(device)
            }
            // The Mobile page: an iPhone paired with a 6-digit code, until that pairing retires.
            if !legacyPairingRetired {
                ManagementChildLinkRows(parent: .devices)
            }
        }
    }

    /// Shows the code an iPhone or iPad scans, from the header's Add Device menu.
    private func addPhone() {
        isJoining = false
        if legacyPairingRetired {
            showScanCode()
        } else {
            model.dismissPairingResult()
            phoneMethod = .ask
            pairSheet = .addPhone
        }
    }

    /// The QR code an iPhone or iPad with Sync scans.
    private func showScanCode() {
        asOwner(L("show a code that adds a device to your sync account")) {
            model.dismissPairingResult()
            model.startPairing()
            phoneMethod = .scan
            pairSheet = .addPhone
        }
    }

    /// Opens the field for another device's pairing link, from the header's Add Device menu.
    private func startJoining() {
        if case .offering = model.pairing { model.cancelPairing() }
        model.dismissPairingResult()
        joinLink = ""
        isJoining = true
        pairSheet = .join
    }

    /// The sheet closed: a code still showing stops working, a number not yet confirmed is turned down, and
    /// how it went is cleared. A join already sent carries on.
    private func endPairing() {
        switch model.pairing {
        case .offering: model.cancelPairing()
        case .confirming: model.rejectPairing()
        case .joining: break
        case .idle, .paired, .failed: model.dismissPairingResult()
        }
        // A 6-digit code still showing stops working with its sheet, as the QR code does.
        if phoneMethod == .code, MobilePairingService.shared.activeCode != nil {
            MobilePairingService.shared.cancelCode()
        }
        phoneMethod = .ask
        codeChosenAt = nil
        isJoining = false
        joinLink = ""
    }

    /// Adding an iPhone or iPad (the code to scan, then the number to check) or joining another device's link,
    /// in a sheet over the page.
    private func pairingSheet(_ kind: PairSheet) -> some View {
        SettingsSheet(
            icon: kind == .addPhone ? "iphone" : "link",
            title: kind == .addPhone ? "Add iPhone or iPad" : "Join Another Device",
            subtitle: sheetSubtitle(kind),
            width: SettingsSheetWidth.regular,
            primary: sheetPrimary(kind),
            onClose: { pairSheet = nil }
        ) {
            VStack(alignment: .leading, spacing: theme.space.s16) {
                switch kind {
                case .addPhone:
                    switch phoneMethod {
                    case .ask:
                        phoneMethodChoice
                    case .code:
                        if let device = phonePairedByCode {
                            SettingsCallout(
                                icon: "checkmark.circle.fill",
                                title: "Device Added",
                                message: String(format: L("%@ is now paired with this Mac."), device.name),
                                tone: .success
                            )
                        } else {
                            MobilePairingCodePanel()
                        }
                    case .scan:
                        if case let .offering(offer) = model.pairing {
                            pairingPanel(offer)
                        } else if model.pairing == .idle {
                            SettingsSpinner()
                        }
                    }
                case .join:
                    if model.pairing == .joining {
                        SettingsSpinner()
                    } else if !isPairingDone {
                        SettingsTextField(
                            placeholder: "osaurus-pair:…",
                            text: $joinLink,
                            monospaced: true,
                            onSubmit: join
                        )
                    }
                }
                pairingResult
            }
        }
    }

    /// Join while there's a link to send; nothing while the number is checked (its own buttons answer it);
    /// otherwise Done.
    private func sheetPrimary(_ kind: PairSheet) -> SettingsSheetFooter.Action? {
        if model.isConfirmingPairing { return nil }
        // The first step answers with its choices.
        if kind == .addPhone, phoneMethod == .ask { return nil }
        if kind == .join, model.pairing != .joining, !isPairingDone {
            return SettingsSheetFooter.Action(
                label: "Join",
                isEnabled: !joinLink.trimmingCharacters(in: .whitespaces).isEmpty,
                handler: join
            )
        }
        return SettingsSheetFooter.Action(label: "Done") { pairSheet = nil }
    }

    private func sheetSubtitle(_ kind: PairSheet) -> LocalizedStringKey? {
        switch (kind, phoneMethod) {
        case (.join, _):
            return "Paste the pairing link from a device that already syncs. This Mac's chats join that device's account."
        case (.addPhone, .ask):
            return nil
        case (.addPhone, .scan):
            return
                "Show a code on this Mac, then scan it with the Osaurus app on your iPhone, or paste its link on another Mac."
        case (.addPhone, .code):
            return "Generate a code here and type it in on your iPhone, on the same network as this Mac."
        }
    }

    /// The iPhone that typed in this sheet's 6-digit code, once it has.
    private var phonePairedByCode: PairedMobileDevice? {
        guard let since = codeChosenAt, let device = legacyPairing.pairedDevice, device.pairedAt >= since else {
            return nil
        }
        return device
    }

    /// The first step of adding an iPhone or iPad: what its pairing screen asks for decides the way.
    private var phoneMethodChoice: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text("What does the Pairing Screen in the Osaurus app on your iPhone or iPad show?", bundle: .module)
                .font(SettingsFont.body)
                .foregroundColor(theme.text.primary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsNavigationRow(
                icon: "qrcode.viewfinder",
                title: "A QR Code to Scan",
                subtitle: "This Mac shows a code for the app to scan."
            ) {
                showScanCode()
            }
            SettingsNavigationRow(
                icon: "number",
                title: "A 6-Digit Code to Enter",
                subtitle: "This Mac makes a code for you to type in on the app."
            ) {
                codeChosenAt = Date()
                phoneMethod = .code
            }
        }
    }

    /// Pairing has ended, added or not: the sheet only has Done left.
    private var isPairingDone: Bool {
        switch model.pairing {
        case .paired, .failed: return true
        default: return false
        }
    }

    /// Joining moves this Mac's chats into the other device's account, so it
    /// asks first, and only for a link from the user's own screen.
    private func join() {
        let link = joinLink
        guard SyncStatusModel.isPairingLink(link) else {
            model.join(link: link)
            return
        }
        guard
            confirm(
                L("Join the other device's account?"),
                L("This Mac's chats move to the account of the device that shows this link, and its chats come here. Only use a link shown on your own device's screen."),
                action: L("Join")
            )
        else { return }
        asOwner(L("add this Mac to another device's sync account")) {
            model.join(link: link)
            isJoining = false
        }
    }

    // MARK: - iPhone


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
                        Button(L("Remove Device…")) { confirmRemove(device) }
                            .disabled(isRemoving)
                    }
                }
            }
        }
    }

    private func deviceDetail(_ device: Device) -> String {
        if device.isSelf { return L("This Mac") }
        let kind = device.devicePlatform.kindLabel
        if device.revoked { return String(format: L("%@ · No longer syncs"), kind) }
        if model.isConnected(device) {
            return model.isRelayed(device)
                ? String(format: L("%@ · Connected through a relay server"), kind)
                : String(format: L("%@ · Connected directly"), kind)
        }
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
                ShareCopyRow(label: L("Pairing link"), value: offer.payload)
                Text("Scan the code with the Osaurus app on your iPhone or iPad, or paste the link there with Paste Link from Mac. On another Mac, paste it into Join Another Device. It works for 5 minutes.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The number goes next to the other device's name, and the question makes
    /// the user look at that device: approving blindly adds whoever is asking.
    private func confirmationPanel(_ confirmation: SyncStatusModel.PairingConfirmation) -> some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            SettingsCallout(
                icon: "number.circle.fill",
                title: "Check the Number",
                message: confirmation.confirmed
                    ? String(format: L("Waiting for you to confirm the same number on %@."), confirmation.name)
                    : String(format: L("Does %@ show this number? Look at its screen. Only confirm if both show the same number."), confirmation.name),
                tone: .info
            ) {
                if confirmation.confirmed {
                    SettingsSpinner(size: .small)
                    SettingsButton(.tertiary, "Cancel") { model.rejectPairing() }
                } else {
                    SettingsButton(.primary, "Numbers Match") { model.confirmPairing() }
                    SettingsButton(.secondary, "They're Different") { model.rejectPairing() }
                }
            }
            // Its border breathes until the number is answered: the pairing waits on the person here.
            .modifier(AwaitingAnswerBorder(active: !confirmation.confirmed, radius: theme.radius.medium))
            HStack(spacing: theme.space.s8) {
                Text(verbatim: SyncStatusModel.groupedConfirmationCode(confirmation.code))
                    .font(SettingsFont.detailTitle)
                    .monospaced()
                    .foregroundColor(theme.text.primary)
                Text(verbatim: confirmation.name)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
            .padding(theme.space.s12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsChrome(.inset)
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
        case let .confirming(confirmation):
            confirmationPanel(confirmation)
        case let .paired(name):
            SettingsCallout(
                icon: "checkmark.circle.fill",
                title: "Device Added",
                message: String(format: L("Your chats now sync with %@."), name),
                tone: .success
            )
        case let .failed(message):
            // The sheet's Done closes it, and closing clears it (`endPairing`).
            SettingsCallout(
                icon: "exclamationmark.circle.fill",
                title: "Pairing Didn't Finish",
                message: message,
                tone: .error
            )
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
        asOwner(L("show your sync recovery phrase")) {
            do {
                phrase = try model.recoveryPhrase()
            } catch {
                actionError = error.syncUserMessage
            }
        }
    }

    // MARK: - Storage

    // MARK: - Overview

    /// Sync's live numbers and its storage, side by side above the settings: how it's doing at a glance.
    private var overviewCard: some View {
        // Side by side where the page is wide enough for both, one above the other where it isn't.
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: theme.space.s16) {
                statusCard
                storageCard
            }
            VStack(spacing: theme.space.s16) {
                statusCard
                storageCard
            }
        }
    }

    /// As Memory's Statistics: a titled strip. Never narrower than this, or the two go one above the other.
    private static let overviewCardMinWidth: CGFloat = 380

    private var statusCard: some View {
        SettingsSection(title: "Connection", anchorId: "settings.sync.status") {
            // The status in full where it fits, else in a word or two.
            ViewThatFits(in: .horizontal) {
                SettingsStatStrip(stats: syncStats(short: false))
                SettingsStatStrip(stats: syncStats(short: true))
            }
        }
        .frame(minWidth: Self.overviewCardMinWidth, maxWidth: .infinity)
    }

    private var storageCard: some View {
        SettingsSection(title: "Storage", anchorId: "settings.sync.storage") {
            SettingsStatStrip(stats: storageStats)
        }
        .frame(minWidth: Self.overviewCardMinWidth, maxWidth: .infinity)
    }

    private func syncStats(short: Bool) -> [SettingsStat] {
        var stats = [
            SettingsStat(label: "Status", value: short ? shortStatusText : statusText, valueTint: statusDot),
            SettingsStat(label: "Waiting to Send", value: String(format: L("%lld messages"), model.pendingMessages)),
        ]
        if model.configuration.networkMode == .anywhere, model.configuration.networkEnabled {
            stats.append(
                SettingsStat(
                    label: "Osaurus Servers",
                    value: model.relays.contains(where: \.connected) ? L("Connected") : L("Not connected")
                )
            )
        }
        return stats
    }

    private var storageStats: [SettingsStat] {
        guard let usage = model.storage else { return [SettingsStat(label: "Total on Disk", value: "—")] }
        return [
            SettingsStat(label: "Synced Chats", value: Self.bytes(usage.syncedEventBytes)),
            SettingsStat(label: "This Mac Only", value: Self.bytes(usage.localEventBytes)),
            SettingsStat(label: "Attachments", value: Self.bytes(usage.attachmentBytes)),
            SettingsStat(
                label: "Total on Disk",
                value: Self.bytes(usage.databaseBytes + usage.attachmentBytes + usage.attachmentCacheBytes)
            ),
        ]
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

    /// Runs `action` once Touch ID or the login password confirms the owner
    /// is at this Mac.
    private func asOwner(_ reason: String, _ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            guard await CredentialReveal.confirmOwner(reason: reason) else { return }
            action()
        }
    }

    /// One flow for every removal. Changing the phrase is the default: a
    /// removed device that wasn't wiped still holds the account secret.
    private func confirmRemove(_ device: Device) {
        guard !isRemoving else { return }
        let alert = NSAlert()
        alert.messageText = String(format: L("Remove %@?"), device.name)
        let phraseNote =
            model.configuration.walletLinked
            ? L("Sync then gets its own recovery phrase again, since anyone with your Osaurus recovery phrase could derive the old one.")
            : L("The old recovery phrase stops working.")
        alert.informativeText = String(
            format: L("It stops receiving your chats. Unless it was wiped, it still holds your account's keys, so changing the recovery phrase is what keeps it out. %@ Your other devices pick up the change the next time they connect. Choose Remove Only for a device you've wiped."),
            phraseNote
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Remove and Change Phrase"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Remove Only"))
        let rotate: Bool
        switch alert.runModal() {
        case .alertFirstButtonReturn: rotate = true
        case .alertThirdButtonReturn: rotate = false
        default: return
        }
        asOwner(L("remove a device from your sync account")) {
            guard !isRemoving else { return }
            isRemoving = true
            Task { @MainActor in
                defer { isRemoving = false }
                do {
                    if rotate {
                        phrase = nil
                        newPhrase = try await model.revokeAndRotate(device)
                    } else {
                        try await model.revoke(device)
                    }
                } catch {
                    actionError = error.syncUserMessage
                }
            }
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
        asOwner(L("move this Mac to another sync account")) {
            do {
                try model.recover(phrase: restoreText)
                isRestoring = false
                restoreText = ""
                phrase = nil
            } catch {
                actionError = error.syncUserMessage
            }
        }
    }

    private func confirmUseWalletPhrase() {
        let message =
            model.otherDeviceCount > 0
            ? L("This Mac's sync account changes to the one your Osaurus recovery phrase restores, and it keeps its chats. Your other devices stop syncing with this Mac until you do the same on each of them.")
            : L("This Mac's sync account changes to the one your Osaurus recovery phrase restores, and it keeps its chats. Your current sync phrase stops working.")
        guard confirm(L("Use your Osaurus recovery phrase for sync?"), message, action: L("Use Phrase")) else { return }
        asOwner(L("change your sync recovery phrase")) { useWalletPhrase() }
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
        asOwner(L("sign this Mac out of sync")) {
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
}

/// A slow pulse of a card's border while it waits on the person (the number check). Still, at its brighter
/// edge, with Reduce Motion.
private struct AwaitingAnswerBorder: ViewModifier {
    let active: Bool
    let radius: CGFloat

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One fade in and out, in seconds.
    private static let period: Double = 2.4

    func body(content: Content) -> some View {
        content.overlay {
            if active {
                // Drawn from the clock, not a repeating animation: `withAnimation(.repeatForever)` ran in the
                // transaction that also laid out the sheet (the code giving way to this card), so the whole
                // sheet kept animating with it.
                TimelineView(.animation(paused: reduceMotion)) { context in
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(theme.status.info.foreground, lineWidth: 1.5)
                        .opacity(reduceMotion ? 0.7 : Self.opacity(at: context.date))
                }
                .allowsHitTesting(false)
            }
        }
    }

    /// 0.2 to 0.85 and back, eased.
    private static func opacity(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
        let wave = (1 - cos(phase * 2 * .pi)) / 2
        return 0.2 + 0.65 * wave
    }
}
