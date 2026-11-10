//
//  WhatsAppSettingsView.swift
//  osaurus
//
//  Configuration sheet for the native WhatsApp channel.
//
//  WhatsApp has no bot token: the connection is the local `osaurus-wa`
//  helper (a whatsmeow WhatsApp Web bridge) linked to the user's own
//  WhatsApp account by scanning a QR code — the same "Linked Devices" flow
//  as WhatsApp Web in a browser. Connect therefore verifies helper
//  integrity and drives QR pairing instead of credentials.
//

import CoreImage
import SwiftUI

#if os(macOS)
    import AppKit
#endif

struct WhatsAppSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var helperInstallState = WhatsAppHelperInstallState.shared
    @Environment(\.dismiss) private var dismiss

    /// Set when this sheet is hosted inside the unified Add Channel picker;
    /// shows a back chevron that returns to the catalog.
    var onBack: (() -> Void)? = nil

    @State private var readableChatIdsText: String = ""
    @State private var writableChatIdsText: String = ""
    @State private var senderAllowlistText: String = ""
    @State private var writeEnabled: Bool = false
    @State private var defaultReadLimit: String = "50"
    @State private var receiveEnabled: Bool = false
    @State private var ignoreSelfMessages: Bool = true
    @State private var sendReadReceipts: Bool = false
    @State private var attachmentIngestionEnabled: Bool = false
    @State private var allowedAttachmentRootsText: String = ""
    @State private var maxAttachmentMB: String = "25"
    /// Incoming messages are handled by the events that listen to this
    /// channel; these read them so readiness checks stay honest.
    private var channelEvents: [OsaurusEvent] {
        EventManager.shared.events(kind: .whatsapp, connectionId: AgentChannelConnection.nativeWhatsAppConnectionId).filter(\.isEnabled)
    }
    private var inboundDispatchEnabled: Bool { !channelEvents.isEmpty }
    private var inboundAutoReplyEnabled: Bool {
        channelEvents.contains { $0.reply.replies(for: $0.action.kind) }
    }
    @State private var statusMessage: String?
    @State private var statusDetails: [String] = []
    @State private var statusIsError = false
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var isDiscovering = false
    @State private var isVerifying = false
    @State private var isUnlinking = false
    @State private var healthRefreshToken = 0
    @State private var activityRefreshToken = 0
    @State private var diagnostics: WhatsAppConnectionDiagnostics?
    @State private var discoveredChats: [DiscoveredChat] = []
    @State private var chatSearch = ""
    @State private var selectedSectionId: String = AgentChannelProviderSetupSection.connect.rawValue
    @State private var attentionSectionId: String?
    @State private var verifySucceeded = false
    @State private var lastSavedDraft: DraftSnapshot?
    @State private var autosaveTask: Task<Void, Never>?

    // QR pairing session state.
    @State private var isPairing = false
    @State private var pairingQRCode: String?
    @State private var pairingTask: Task<Void, Never>?

    // Passkey linking gate state (WhatsApp's WebAuthn check after the scan).
    @State private var passkeyChallengeJSON: String?
    @State private var passkeyConfirmCode: String?
    @State private var passkeyResponseText = ""
    @State private var passkeyBusy = false

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private struct DiscoveredChat: Identifiable, Equatable {
        let id: String
        let name: String
        let kind: String
    }

    /// Everything the configuration save persists, as one Equatable value —
    /// a single `onChange` on this drives autosave.
    private struct DraftSnapshot: Equatable {
        var readableChatIdsText: String
        var writableChatIdsText: String
        var senderAllowlistText: String
        var writeEnabled: Bool
        var defaultReadLimit: String
        var receiveEnabled: Bool
        var ignoreSelfMessages: Bool
        var sendReadReceipts: Bool
        var attachmentIngestionEnabled: Bool
        var allowedAttachmentRootsText: String
        var maxAttachmentMB: String
    }

    private var currentDraft: DraftSnapshot {
        DraftSnapshot(
            readableChatIdsText: readableChatIdsText,
            writableChatIdsText: writableChatIdsText,
            senderAllowlistText: senderAllowlistText,
            writeEnabled: writeEnabled,
            defaultReadLimit: defaultReadLimit,
            receiveEnabled: receiveEnabled,
            ignoreSelfMessages: ignoreSelfMessages,
            sendReadReceipts: sendReadReceipts,
            attachmentIngestionEnabled: attachmentIngestionEnabled,
            allowedAttachmentRootsText: allowedAttachmentRootsText,
            maxAttachmentMB: maxAttachmentMB
        )
    }

    var body: some View {
        AgentChannelSetupScaffold(
            icon: AgentChannelKind.whatsapp.icon,
            gradient: AgentChannelKind.whatsapp.brandGradient,
            title: AgentChannelKind.whatsapp.displayName,
            subtitle: L("Read and reply in allowlisted WhatsApp chats via a QR-linked bridge"),
            sections: AgentChannelProviderSetupSection.sections,
            selection: $selectedSectionId,
            sectionStatus: sectionStatus(for:),
            onBack: onBack
        ) { sectionId in
            VStack(alignment: .leading, spacing: 20) {
                switch AgentChannelProviderSetupSection(rawValue: sectionId) {
                case .connect:
                    connectSectionContent
                case .receiving:
                    accessSectionContent
                case .routing:
                    routingSectionContent
                case .sending:
                    sendingSectionContent
                case .verify, nil:
                    stepVerifySection
                }
            }
        } statusBar: {
            if let statusMessage {
                AgentChannelInlineStatusMessage(
                    message: statusMessage,
                    details: statusDetails,
                    isError: statusIsError,
                    onAutoClear: { clearStatus() }
                )
            }
        } footerLeading: {
            AgentChannelSheetActionButton(
                title: L("Test Connection"),
                busyTitle: L("Testing..."),
                isBusy: isTesting,
                action: testConnection
            )
            .disabled(isTesting || isSaving)
        } footerTrailing: {
            AgentChannelSheetActionButton(
                title: L("Done"),
                busyTitle: L("Saving..."),
                isBusy: isSaving,
                isPrimary: true,
                action: saveAndDismiss
            )
            .disabled(isSaving)
        }
        .onAppear {
            loadConfiguration()
            selectedSectionId = AgentChannelSetupFlow.initialSection(
                in: AgentChannelProviderSetupSection.sections,
                required: AgentChannelProviderSetupSection.requiredSectionIds,
                isComplete: { sectionCompleted($0) },
                fallback: AgentChannelProviderSetupSection.verify.rawValue
            )
            refreshDiagnostics()
        }
        .onChange(of: currentDraft) { _, _ in
            scheduleAutosave()
        }
        .onDisappear {
            autosaveTask?.cancel()
            autosaveNow()
            stopPairing()
        }
    }

    // MARK: - Autosave

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        guard lastSavedDraft != nil, currentDraft != lastSavedDraft else { return }
        autosaveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            autosaveNow()
        }
    }

    private func autosaveNow() {
        guard lastSavedDraft != nil, currentDraft != lastSavedDraft else { return }
        guard validationFailure() == nil else { return }
        guard (try? WhatsAppConnectionService.shared.saveConfiguration(currentConfiguration())) != nil
        else { return }
        lastSavedDraft = currentDraft
        refreshReceiveRuntime()
    }

    // MARK: - Section state

    /// Send-only is a valid setup: writing needs the helper and a linked
    /// account but neither the receive toggle nor a sender allowlist.
    private var isSendOnlySetup: Bool {
        !receiveEnabled && writeEnabled
    }

    private func sectionCompleted(_ sectionId: String) -> Bool {
        switch AgentChannelProviderSetupSection(rawValue: sectionId) {
        case .connect:
            guard diagnostics?.helperVerified ?? false, diagnostics?.linked ?? false else {
                return false
            }
            return isSendOnlySetup || receiveEnabled
        case .receiving:
            if isSendOnlySetup {
                return !parseIds(writableChatIdsText).isEmpty
            }
            return !parseIds(readableChatIdsText).isEmpty && !parseIds(senderAllowlistText).isEmpty
        case .routing:
            return inboundDispatchEnabled
        case .sending:
            return writeEnabled
        case .verify:
            return verifySucceeded
        case nil:
            return false
        }
    }

    private func sectionStatus(for sectionId: String) -> AgentChannelSetupSectionStatus {
        if attentionSectionId == sectionId { return .attention }
        return sectionCompleted(sectionId) ? .complete : .pending
    }

    // MARK: - Connect

    private var connectSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(
                "WhatsApp runs through a local bridge helper speaking the WhatsApp Web protocol, linked to your own account like a browser session — no bot account, token, or Meta Business setup. This uses an unofficial protocol: WhatsApp may log the session out, and a dedicated number is recommended.",
                bundle: .module
            )
            .font(SettingsFont.caption)
            .foregroundColor(theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)

            helperStatusSection
            linkSection
            stepReceiveSection
        }
    }

    private var helperStatusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(L("WhatsApp bridge helper"))
            helperRow
            if case .failed(let message) = helperInstallState.phase {
                Text(message)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.status.error.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, theme.space.s24)
            }
        }
    }

    private var helperRow: some View {
        let helperVerified = diagnostics?.helperVerified ?? false
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: helperIconName)
                .glyphSize(13)
                .foregroundColor(helperIconColor)
                .padding(.top, theme.space.s2)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Integrity-verified helper (osaurus-wa)"))
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Text(helperDetailText)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if !helperVerified && helperDownloadAvailable {
                AgentChannelSheetActionButton(
                    title: L("Download"),
                    busyTitle: helperInstallBusyTitle,
                    isBusy: helperInstallState.isBusy
                ) {
                    downloadHelper()
                }
            }
        }
    }

    /// Offer the download when no helper resolved, or when a previous copy
    /// failed integrity (re-download restores a pin-matching install). While
    /// digests are unpinned there is nothing verifiable to download.
    private var helperDownloadAvailable: Bool {
        guard WhatsAppRuntimeAssets.digestsPinned else { return false }
        switch diagnostics?.helperState {
        case "missing", "digest_mismatch": return true
        default: return false
        }
    }

    private var helperInstallBusyTitle: String {
        switch helperInstallState.phase {
        case .downloading(let fraction):
            if let fraction {
                return String(
                    format: L("Downloading %d%%"),
                    Int((fraction * 100).rounded())
                )
            }
            return L("Downloading...")
        case .installing:
            return L("Verifying...")
        default:
            return L("...")
        }
    }

    private func downloadHelper() {
        Task {
            do {
                try await WhatsAppHelperInstaller.shared.installFromRelease()
            } catch {
                // State already reflects the failure; nothing else to do.
            }
            refreshDiagnostics()
        }
    }

    private var helperIconName: String {
        switch diagnostics?.helperState {
        case "verified", "dev_override": return "checkmark.circle.fill"
        case "digest_mismatch", "unpinned": return "xmark.circle.fill"
        default: return "circle"
        }
    }

    private var helperIconColor: Color {
        switch diagnostics?.helperState {
        case "verified", "dev_override": return theme.status.success.foreground
        case "digest_mismatch", "unpinned": return theme.status.warning.foreground
        default: return theme.text.tertiary
        }
    }

    private var helperDetailText: String {
        switch diagnostics?.helperState {
        case "verified":
            return L("Pinned to an open-source release and checksum-verified before every launch.")
        case "dev_override":
            return L("Using the developer override binary (OSAURUS_WA_PATH).")
        case "digest_mismatch":
            return L("Integrity check failed — reinstall a verified copy.")
        case "unpinned":
            return L(
                "No release digests are pinned in this build. Build the helper locally with `make wa-helper` and point OSAURUS_WA_PATH at build/osaurus-wa (DEBUG builds), or run an app bundle with the helper sealed inside."
            )
        default:
            return L(
                "The whatsmeow-based bridge helper is required for all WhatsApp actions. Build it with `make wa-helper` (needs the Go toolchain)."
            )
        }
    }

    // MARK: - Link (QR pairing)

    private var linkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Link your WhatsApp account"))

            linkStatusRow

            if isPairing {
                pairingCard
            }
        }
    }

    private var linkStatusRow: some View {
        let linked = diagnostics?.linked ?? false
        let detail: String
        if linked {
            if let number = diagnostics?.selfNumber, !number.isEmpty {
                detail = String(format: L("Linked as %@."), number)
            } else {
                detail = L("A WhatsApp account is linked on this Mac.")
            }
        } else {
            detail = L(
                "Scan a QR code from your phone: WhatsApp → Settings → Linked Devices → Link a Device."
            )
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: linked ? "checkmark.circle.fill" : "qrcode")
                .glyphSize(13)
                .foregroundColor(linked ? theme.status.success.foreground : theme.text.tertiary)
                .padding(.top, theme.space.s2)
            VStack(alignment: .leading, spacing: 2) {
                Text(linked ? L("Account linked") : L("No account linked"))
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Text(detail)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if linked {
                AgentChannelSheetActionButton(
                    title: L("Unlink"),
                    busyTitle: L("Unlinking..."),
                    isBusy: isUnlinking,
                    action: unlinkAccount
                )
                .disabled(isUnlinking || isPairing)
            } else if !isPairing {
                AgentChannelSheetActionButton(
                    title: L("Link with QR"),
                    busyTitle: L("Starting..."),
                    isBusy: false,
                    isPrimary: true,
                    action: startPairing
                )
                .disabled(!(diagnostics?.helperVerified ?? false))
            }
        }
    }

    private var pairingCard: some View {
        VStack(spacing: 10) {
            if let code = passkeyConfirmCode {
                passkeyConfirmContent(code: code)
            } else if passkeyChallengeJSON != nil {
                passkeyChallengeContent
            } else if let code = pairingQRCode, let image = Self.qrImage(for: code, side: 220) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .background(FixedPalette.qrPaper)
                    .clipShape(RoundedRectangle(cornerRadius: theme.radius.medium))
                Text(
                    "Scan with your phone: WhatsApp → Settings → Linked Devices → Link a Device. Codes rotate about every 20 seconds.",
                    bundle: .module
                )
                .font(SettingsFont.footnote)
                .foregroundColor(theme.text.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Waiting for a QR code from the helper...", bundle: .module)
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }

            AgentChannelSheetActionButton(
                title: L("Cancel Pairing"),
                busyTitle: L("..."),
                isBusy: false,
                action: stopPairing
            )
        }
        .frame(maxWidth: .infinity)
        .padding(theme.space.s16)
        .settingsChrome(.inset)
    }

    // MARK: - Passkey linking gate

    /// The WebAuthn assertion must be produced by the account's own passkey
    /// bound to the web.whatsapp.com origin, which a third-party app cannot
    /// request directly. The user runs one command in a web.whatsapp.com
    /// browser tab (approving the passkey prompt there) and pastes the JSON
    /// back — the same flow other WhatsApp bridges use for this gate.
    private var passkeyChallengeContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("This account is protected by a passkey"), systemImage: "person.badge.key.fill")
                .textStyle(.caption, weight: 600)
                .foregroundColor(theme.text.primary)
            Text(
                "WhatsApp requires a passkey check to link a new device. In a browser, open web.whatsapp.com, open the developer console (Cmd-Opt-J or F12), run the copied command, approve the passkey prompt, then paste the JSON line it prints below.",
                bundle: .module
            )
            .font(SettingsFont.footnote)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            AgentChannelSheetActionButton(
                title: L("Copy Browser Command"),
                busyTitle: L("..."),
                isBusy: false,
                action: copyPasskeyCommand
            )

            SettingsTextEditor(text: $passkeyResponseText, minHeight: 64, maxHeight: 64, monospaced: true)

            AgentChannelSheetActionButton(
                title: L("Submit Passkey Response"),
                busyTitle: L("Submitting..."),
                isBusy: passkeyBusy,
                isPrimary: true,
                action: submitPasskeyResponse
            )
            .disabled(
                passkeyResponseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func passkeyConfirmContent(code: String) -> some View {
        VStack(spacing: 8) {
            Label(L("Check your phone"), systemImage: "iphone.badge.play")
                .textStyle(.caption, weight: 600)
                .foregroundColor(theme.text.primary)
            Text(code)
                .font(SettingsFont.mono)
                .foregroundColor(theme.text.primary)
            Text(
                "Confirm this code matches the one WhatsApp shows on your phone, then continue.",
                bundle: .module
            )
            .font(SettingsFont.footnote)
            .foregroundColor(theme.text.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            AgentChannelSheetActionButton(
                title: L("The Codes Match — Continue"),
                busyTitle: L("Confirming..."),
                isBusy: passkeyBusy,
                isPrimary: true,
                action: confirmPasskeyCode
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func copyPasskeyCommand() {
        guard let optionsJSON = passkeyChallengeJSON else { return }
        let command = """
            const opts = PublicKeyCredential.parseRequestOptionsFromJSON(\(optionsJSON));
            const cred = await navigator.credentials.get({ publicKey: opts });
            console.log(JSON.stringify(cred.toJSON()));
            """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        showStatus(L("Browser command copied. Run it in a web.whatsapp.com console tab."), isError: false)
    }

    private func submitPasskeyResponse() {
        guard !passkeyBusy else { return }
        passkeyBusy = true
        let response = passkeyResponseText
        Task {
            do {
                try await WhatsAppConnectionService.shared.submitPasskeyResponse(response)
                await MainActor.run {
                    passkeyBusy = false
                    showStatus(L("Passkey response accepted — finishing the link..."), isError: false)
                }
            } catch {
                await MainActor.run {
                    passkeyBusy = false
                    showStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func confirmPasskeyCode() {
        guard !passkeyBusy else { return }
        passkeyBusy = true
        Task {
            do {
                try await WhatsAppConnectionService.shared.confirmPasskeyCode()
                await MainActor.run { passkeyBusy = false }
            } catch {
                await MainActor.run {
                    passkeyBusy = false
                    showStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func resetPasskeyState() {
        passkeyChallengeJSON = nil
        passkeyConfirmCode = nil
        passkeyResponseText = ""
        passkeyBusy = false
    }

    /// Render one rotating pairing code as a QR image via CoreImage.
    private static func qrImage(for code: String, side: CGFloat) -> NSImage? {
        guard let data = code.data(using: .utf8),
            let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private func startPairing() {
        guard !isPairing else { return }
        isPairing = true
        pairingQRCode = nil
        resetPasskeyState()
        clearStatus()
        pairingTask = Task {
            do {
                let events = try await WhatsAppConnectionService.shared.startPairing()
                for await event in events {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        switch event {
                        case .qr(let code):
                            pairingQRCode = code
                        case .passkeyChallenge(let publicKeyJSON):
                            pairingQRCode = nil
                            passkeyChallengeJSON = publicKeyJSON
                            passkeyConfirmCode = nil
                        case .passkeyCode(let code):
                            pairingQRCode = nil
                            passkeyConfirmCode = code
                        case .success(let selfNumber):
                            isPairing = false
                            pairingQRCode = nil
                            resetPasskeyState()
                            AgentChannelCredentialAvailability.shared.invalidate(.whatsapp)
                            if let selfNumber, !selfNumber.isEmpty {
                                showStatus(
                                    String(format: L("Linked as %@."), selfNumber),
                                    isError: false
                                )
                            } else {
                                showStatus(L("WhatsApp account linked."), isError: false)
                            }
                            refreshDiagnostics()
                            refreshReceiveRuntime()
                        case .timeout:
                            isPairing = false
                            pairingQRCode = nil
                            resetPasskeyState()
                            showStatus(
                                L("Pairing timed out before the QR code was scanned. Start again when ready."),
                                isError: true
                            )
                        case .failed(let message):
                            isPairing = false
                            pairingQRCode = nil
                            resetPasskeyState()
                            showStatus(message, isError: true)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    isPairing = false
                    pairingQRCode = nil
                    resetPasskeyState()
                    showStatus(error.localizedDescription, isError: true)
                }
            }
            await MainActor.run {
                // Stream finished without a terminal event (e.g. cancelled).
                if isPairing {
                    isPairing = false
                    pairingQRCode = nil
                    resetPasskeyState()
                }
            }
        }
    }

    private func stopPairing() {
        guard isPairing || pairingTask != nil else { return }
        pairingTask?.cancel()
        pairingTask = nil
        isPairing = false
        pairingQRCode = nil
        resetPasskeyState()
        Task { await WhatsAppConnectionService.shared.cancelPairing() }
    }

    private func unlinkAccount() {
        isUnlinking = true
        Task {
            do {
                _ = try await WhatsAppConnectionService.shared.unlink()
                await MainActor.run {
                    isUnlinking = false
                    showStatus(
                        L("Account unlinked. Receiving and sending stay off until you link again."),
                        isError: false
                    )
                    refreshDiagnostics()
                    refreshReceiveRuntime()
                }
            } catch {
                await MainActor.run {
                    isUnlinking = false
                    showStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    private var stepReceiveSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Turn on receiving"))

            SettingsToggle(
                title: "Receive Messages",
                description: L(
                    "Keep a live connection to WhatsApp and store authorized incoming messages in the local inbox while the app runs."
                ),
                isOn: $receiveEnabled.animation(theme.motion.quick)
            )

            if !receiveEnabled {
                Text(
                    writeEnabled
                        ? L(
                            "Receiving is off — send-only setup. Agents can post to writable chats but will not see or reply to incoming WhatsApp messages."
                        )
                        : L("Receiving is off: agents will not see new WhatsApp messages and no agent can reply.")
                )
                .textStyle(.footnote)
                .foregroundColor(writeEnabled ? theme.text.tertiary : theme.status.warning.foreground)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Access

    private var accessSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepAccessSection
            receiveOptionsSection
            attachmentsSection
            advancedSection
        }
    }

    private var stepAccessSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Choose chats and people"))

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(discoveredChats.isEmpty ? L("Load known WhatsApp chats") : L("WhatsApp chats loaded"))
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                    Text(
                        "Requires the helper and a linked account. Chats come from the local session store; nothing leaves this machine.",
                        bundle: .module
                    )
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
                }
                Spacer()
                AgentChannelSheetActionButton(
                    title: discoveredChats.isEmpty ? L("Load from WhatsApp") : L("Refresh"),
                    busyTitle: L("Loading..."),
                    isBusy: isDiscovering,
                    action: refreshChatDiscovery
                )
                .disabled(isDiscovering)
            }

            if !discoveredChats.isEmpty {
                chatSelector
            }

            Text(
                "Read lets agents see a chat, Write lets them post there, and the sender allowlist marks whose messages are handled. Manual IDs are under Advanced.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            senderPickerSection

            if parseIds(senderAllowlistText).isEmpty && !parseIds(readableChatIdsText).isEmpty {
                missingSendersWarning
            }
        }
    }

    /// People are picked, not typed: candidates are the phone numbers of
    /// readable direct chats plus anything already allowlisted. Manual entry
    /// lives under Advanced.
    private var senderPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Authorized senders", bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
            Text(
                "Only messages from allowed phone numbers are handled — required for receive. Manual numbers are under Advanced.",
                bundle: .module
            )
            .font(SettingsFont.footnote)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            if senderCandidates.isEmpty {
                Text(
                    "Mark a direct chat as Read above to choose its number here, or add numbers under Advanced.",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                let allowed = Set(parseIds(senderAllowlistText))
                VStack(spacing: 0) {
                    ForEach(senderCandidates, id: \.self) { handle in
                        HStack(spacing: 9) {
                            Image(systemName: "person.crop.circle")
                                .glyphSize(11, weight: .semibold)
                                .foregroundColor(theme.text.secondary)
                                .frame(width: 20)
                            Text(handle)
                                .font(SettingsFont.monoSmall)
                                .foregroundColor(theme.text.primary)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            AgentChannelSelectorToggle(
                                title: L("Allow"),
                                selected: allowed.contains(handle)
                            ) {
                                senderAllowlistText = toggledIdText(senderAllowlistText, id: handle)
                            }
                        }
                        .padding(.horizontal, theme.space.s8)
                        .padding(.vertical, theme.space.s8)
                        if handle != senderCandidates.last {
                        }
                    }
                }
                .settingsChrome(.inset)
            }
        }
    }

    /// Sender candidates: readable direct chats are phone numbers (the same
    /// id space as the sender allowlist); group JIDs carry no single sender.
    private var senderCandidates: [String] {
        var handles: [String] = []
        for id in parseIds(readableChatIdsText) where id.hasPrefix("+") {
            handles.append(id)
        }
        handles.append(contentsOf: parseIds(senderAllowlistText))
        return WhatsAppConnectionConfiguration.normalizedIds(handles)
    }

    /// The most common setup trap: chats are selected but the sender
    /// allowlist is empty, so receiving silently never starts.
    private var missingSendersWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .glyphSize(11)
                .foregroundColor(theme.status.warning.foreground)
                .padding(.top, theme.space.s2)
            Text(
                "Receiving stays off until you add at least one authorized sender.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.status.warning.foreground)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chatSelector: some View {
        let readableIds = Set(parseIds(readableChatIdsText))
        let writableIds = Set(parseIds(writableChatIdsText))
        let shaped = AgentChannelSelectorList.shape(
            discoveredChats,
            query: chatSearch,
            fields: { [$0.name, $0.id, $0.kind] },
            state: {
                AgentChannelReadWriteSelection(
                    read: readableIds.contains($0.id),
                    write: writableIds.contains($0.id)
                )
            },
            isSelected: { $0.isSelected }
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Known Chats", bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .foregroundColor(theme.text.primary)
                Spacer()
                Text("\(discoveredChats.count) found")
                    .font(SettingsFont.footnote)
                    .foregroundColor(theme.text.tertiary)
            }

            AgentChannelSelectorSearchField(
                placeholder: L("Search chats by name or number"),
                text: $chatSearch
            )

            AgentChannelSelectorListCard(
                shaped: shaped,
                emptyText: L("No matching WhatsApp chats")
            ) { item in
                chatRow(item.entry, access: item.state)
            }
        }
    }

    private func chatRow(
        _ chat: DiscoveredChat,
        access: AgentChannelReadWriteSelection
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: chat.kind == "group" ? "person.3.fill" : "person.crop.circle.fill")
                .glyphSize(11, weight: .semibold)
                .foregroundColor(theme.text.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(chat.name)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.primary)
                    .lineLimit(1)
                Text(chat.id)
                    .font(SettingsFont.monoSmall)
                    .foregroundColor(theme.text.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            AgentChannelSelectorToggle(title: L("Read"), selected: access.read) {
                readableChatIdsText = toggledIdText(readableChatIdsText, id: chat.id)
            }
            AgentChannelSelectorToggle(title: L("Write"), selected: access.write) {
                writableChatIdsText = toggledIdText(writableChatIdsText, id: chat.id)
            }
        }
        .padding(.horizontal, theme.space.s8)
        .padding(.vertical, theme.space.s8)
    }

    private var advancedSection: some View {
        AgentChannelAdvancedSection {
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    "Manual IDs are a fallback for chats not returned by discovery. Direct chats use E.164 phone numbers (+15551234567); groups use their JID (1203630XXXX@g.us).",
                    bundle: .module
                )
                .font(SettingsFont.rowDescription)
                .foregroundColor(theme.text.tertiary)

                AgentChannelMultilineSettingsField(
                    title: L("Readable Chat IDs"),
                    text: $readableChatIdsText,
                    placeholder: L("+15551234567 or 1203630XXXX@g.us — one per line"),
                    help: L("Chats agents may read.")
                )
                AgentChannelMultilineSettingsField(
                    title: L("Authorized Senders"),
                    text: $senderAllowlistText,
                    placeholder: L("+15551234567 — one per line"),
                    help: L("Only messages from these numbers trigger inbound handling; required for receive.")
                )
                SettingsTextFieldRow(
                    label: "Default Read Limit",
                    text: $defaultReadLimit,
                    placeholder: "50",
                    help: "Default recent-message count for WhatsApp reads. Clamped to 1-100."
                )
            }
        }
    }

    // MARK: - Behavior

    private var routingSectionContent: some View {
        ChannelRoutingSection(kind: .whatsapp, connectionId: AgentChannelConnection.nativeWhatsAppConnectionId)
    }

    private var sendingSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            sendingSection
            ChannelPostingSection(kind: .whatsapp, connectionId: AgentChannelConnection.nativeWhatsAppConnectionId)
        }
    }

    private var receiveOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Incoming message options"))

            SettingsToggle(
                title: "Ignore Messages You Send",
                description: L(
                    "Skip messages sent from the linked account itself (including your phone and other linked devices). Turn this off to test the full loop from a single number by messaging yourself — the sender must still be in the authorized list, and automatic replies can loop if the agent answers itself."
                ),
                isOn: $ignoreSelfMessages
            )

            SettingsToggle(
                title: "Send Read Receipts",
                description: L(
                    "Mark handled messages as read on WhatsApp (blue ticks) after they are stored. Senders can see this."
                ),
                isOn: $sendReadReceipts
            )
        }
    }

    private var attachmentsSection: some View {
        SettingsFieldRow(label: "Attachments") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggle(
                    title: "Handle Attachments",
                    description: L(
                        "Download incoming media (images, video, audio, documents) from allowlisted chats so agents can use it, and allow agents to send files from the allowed folders below."
                    ),
                    isOn: $attachmentIngestionEnabled.animation(theme.motion.quick)
                )

                if attachmentIngestionEnabled {
                    VStack(alignment: .leading, spacing: 12) {
                        AgentChannelMultilineSettingsField(
                            title: L("Allowed Attachment Folders"),
                            text: $allowedAttachmentRootsText,
                            placeholder: WhatsAppConnectionConfiguration.defaultAttachmentRoots
                                .joined(separator: "\n"),
                            help: L(
                                "Agents may only send files from inside these folders. Downloaded media always lands in the default media folder, which stays allowed."
                            )
                        )
                        SettingsTextFieldRow(
                            label: "Max Attachment Size (MB)",
                            text: $maxAttachmentMB,
                            placeholder: "25",
                            help: L(
                                "Larger incoming media is skipped (the message still arrives with a placeholder) and larger outgoing files are refused."
                            )
                        )
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private var sendingSection: some View {
        SettingsFieldRow(label: "Sending") {
            VStack(alignment: .leading, spacing: 12) {
                SettingsToggle(
                    title: "Allow Sending on WhatsApp",
                    description: L(
                        "Let agents post to write-allowlisted chats through the linked account. The global Sending switch in Channels must also be on."
                    ),
                    isOn: $writeEnabled.animation(theme.motion.quick)
                )

                if writeEnabled {
                    AgentChannelMultilineSettingsField(
                        title: L("Writable Chat IDs"),
                        text: $writableChatIdsText,
                        placeholder: L("+15551234567 or 1203630XXXX@g.us — one per line"),
                        help: L("Chats agents may post to.")
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    // MARK: - Verify

    private var stepVerifySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Verify an incoming message"))

            Text(
                "Changes save automatically, and receiving starts once Connect and Conversations are complete. Send a WhatsApp message from an authorized sender in a readable chat, then watch each stage appear here.",
                bundle: .module
            )
            .font(SettingsFont.rowDescription)
            .foregroundColor(theme.text.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            AgentChannelTransportHealthView(
                connectionId: WhatsAppConnectionService.nativeConnectionId,
                transportId: WhatsAppWatchTransportRuntime.transportId,
                title: L("WhatsApp receive"),
                notRunningHint: L(
                    "Receiving is not running. Verify the helper and QR link, turn on Receive Messages, then add readable chats and authorized senders to start it."
                ),
                refreshToken: healthRefreshToken
            )

            AgentChannelInboundActivityListView(
                connectionId: WhatsAppConnectionService.nativeConnectionId,
                emptyHint: L(
                    "No incoming WhatsApp messages yet this session. Send one from an authorized sender and press “Verify incoming message”."
                ),
                refreshToken: activityRefreshToken
            )

            AgentChannelSheetActionButton(
                title: L("Verify incoming message"),
                busyTitle: L("Waiting for a WhatsApp message..."),
                isBusy: isVerifying,
                action: verifyIncomingMessage
            )
            .disabled(isVerifying || isSaving || isTesting)
        }
    }


    // MARK: - Load / save

    private func loadConfiguration() {
        let configuration = WhatsAppConnectionConfigurationStore.load()
        readableChatIdsText = configuration.readableChatIds.joined(separator: "\n")
        writableChatIdsText = configuration.writableChatIds.joined(separator: "\n")
        senderAllowlistText = configuration.senderAllowlist.joined(separator: "\n")
        writeEnabled = configuration.writeEnabled
        defaultReadLimit = "\(configuration.defaultReadLimit)"
        receiveEnabled = configuration.receiveEnabled
        ignoreSelfMessages = configuration.ignoreSelfMessages
        sendReadReceipts = configuration.sendReadReceipts
        attachmentIngestionEnabled = configuration.attachmentIngestionEnabled
        allowedAttachmentRootsText = configuration.allowedAttachmentRoots.joined(separator: "\n")
        maxAttachmentMB = "\(configuration.maxAttachmentBytes / (1_024 * 1_024))"
        // Arm autosave only after the stored configuration has hydrated the
        // draft, so hydration itself is never mistaken for an edit.
        lastSavedDraft = currentDraft
    }

    private func validationFailure() -> (message: String, section: AgentChannelProviderSetupSection)? {
        if inboundDispatchEnabled, inboundAutoReplyEnabled {
            guard writeEnabled else {
                return (L("Enable WhatsApp sending before automatic channel replies."), .sending)
            }
            let missing = ChannelAgentRoster.autoReplyRoomsNotWritable(
                ChannelAgentRoster.replyingRules(channelEvents),
                readable: parseIds(readableChatIdsText), writable: parseIds(writableChatIdsText))
            guard missing.isEmpty else {
                return (
                    L(
                        "Automatic replies need these WhatsApp chats to be writable: \(missing.joined(separator: ", ")). Make them writable, or set their routing rules to After approval."
                    ),
                    .receiving
                )
            }
        }
        return nil
    }

    private func currentConfiguration() -> WhatsAppConnectionConfiguration {
        // The default media folder stays allowed so downloaded media is
        // always re-shareable, even if the user pruned the roots list.
        let roots = WhatsAppConnectionConfiguration.normalizedRoots(
            allowedAttachmentRootsText
                .components(separatedBy: CharacterSet(charactersIn: "\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                + WhatsAppConnectionConfiguration.defaultAttachmentRoots
        )
        return WhatsAppConnectionConfiguration(
            readableChatIds: parseIds(readableChatIdsText),
            writableChatIds: parseIds(writableChatIdsText),
            senderAllowlist: parseIds(senderAllowlistText),
            writeEnabled: writeEnabled,
            defaultReadLimit: Int(defaultReadLimit) ?? 50,
            ignoreSelfMessages: ignoreSelfMessages,
            receiveEnabled: receiveEnabled,
            sendReadReceipts: sendReadReceipts,
            attachmentIngestionEnabled: attachmentIngestionEnabled,
            allowedAttachmentRoots: roots,
            maxAttachmentBytes: (Int(maxAttachmentMB) ?? 25) * 1_024 * 1_024
        )
    }

    @discardableResult
    private func saveConfiguration() -> Bool {
        if let failure = validationFailure() {
            showStatus(failure.message, isError: true, section: failure.section)
            return false
        }
        do {
            try WhatsAppConnectionService.shared.saveConfiguration(currentConfiguration())
            lastSavedDraft = currentDraft
            return true
        } catch {
            showStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    private func saveAndDismiss() {
        autosaveTask?.cancel()
        isSaving = true
        Task {
            guard saveConfiguration() else {
                isSaving = false
                return
            }
            await AgentChannelTransportSupervisor.shared.refreshWhatsAppRuntime()
            let latest = await WhatsAppConnectionService.shared.diagnostics()
            let report = AgentChannelLiveProofReadiness.whatsApp(latest)
            await MainActor.run {
                isSaving = false
                diagnostics = latest
                healthRefreshToken += 1

                if inboundDispatchEnabled {
                    if report.isReadyForLiveProof {
                        _ = ToastManager.shared.success(
                            L("WhatsApp settings saved — receive is ready")
                        )
                        clearStatus()
                        dismiss()
                    } else {
                        showStatus(
                            L("Saved, but WhatsApp receive is not ready yet"),
                            details: report.blockers + report.notes,
                            isError: true,
                            section: .verify
                        )
                    }
                    return
                }

                let presentation = AgentChannelStatusPresentation.diagnostics(status: latest.status)
                if latest.failures.isEmpty {
                    _ = ToastManager.shared.success(L("WhatsApp settings saved"))
                    clearStatus()
                    dismiss()
                } else {
                    _ = ToastManager.shared.warning(
                        presentation.label,
                        message: latest.failures.first,
                        timeout: 8
                    )
                    showDiagnostics(latest, presentation: presentation)
                }
            }
        }
    }

    private func testConnection() {
        autosaveTask?.cancel()
        isTesting = true
        Task {
            guard saveConfiguration() else {
                isTesting = false
                return
            }
            await WhatsAppConnectionService.shared.probeAndCacheLinkStatus()
            await AgentChannelTransportSupervisor.shared.refreshWhatsAppRuntime()
            let latest = await WhatsAppConnectionService.shared.diagnostics()
            await MainActor.run {
                isTesting = false
                diagnostics = latest
                healthRefreshToken += 1
                showDiagnostics(latest)
            }
        }
    }

    private func refreshDiagnostics() {
        Task {
            await WhatsAppConnectionService.shared.probeAndCacheLinkStatus()
            let latest = await WhatsAppConnectionService.shared.diagnostics()
            await MainActor.run { diagnostics = latest }
        }
    }

    private func refreshChatDiscovery() {
        isDiscovering = true
        Task {
            do {
                let rows = try await WhatsAppConnectionService.shared.listChats()
                await MainActor.run {
                    discoveredChats = rows.compactMap { row in
                        guard let id = row["id"] as? String, !id.isEmpty else { return nil }
                        return DiscoveredChat(
                            id: id,
                            name: (row["name"] as? String) ?? id,
                            kind: (row["kind"] as? String) ?? "chat"
                        )
                    }
                    isDiscovering = false
                    if discoveredChats.isEmpty {
                        showStatus(
                            L("No chats came back. Verify the helper is installed and the account is linked."),
                            isError: true
                        )
                    } else {
                        showStatus(L("Loaded known WhatsApp chats."), isError: false)
                    }
                }
            } catch {
                await MainActor.run {
                    isDiscovering = false
                    showStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func refreshReceiveRuntime() {
        Task {
            await AgentChannelTransportSupervisor.shared.refreshWhatsAppRuntime()
            await MainActor.run { healthRefreshToken += 1 }
        }
    }

    private func verifyIncomingMessage() {
        isVerifying = true
        showStatus(
            L("Waiting for a WhatsApp message. Send one now from an authorized sender in a readable chat."),
            isError: false
        )
        let start = Date()
        let autoReply = inboundAutoReplyEnabled
        Task {
            let outcome = await AgentChannelInboundVerifier.waitForTerminalEvent(
                connectionId: WhatsAppConnectionService.nativeConnectionId,
                since: start,
                autoReplyEnabled: autoReply,
                onActivity: {
                    activityRefreshToken += 1
                    healthRefreshToken += 1
                }
            )
            await MainActor.run {
                isVerifying = false
                activityRefreshToken += 1
                if let event = outcome.event {
                    presentVerifyOutcome(event, timedOutWaitingForMore: outcome.timedOutWaitingForMore)
                } else {
                    showStatus(
                        L("No WhatsApp message arrived within 90 seconds."),
                        details: [
                            L("Confirm the message came from an authorized sender in a readable chat."),
                            L("Confirm Receive Messages is on and the account is linked."),
                            L("Confirm the receive transport above shows as running."),
                        ],
                        isError: true
                    )
                }
            }
        }
    }

    private func presentVerifyOutcome(
        _ event: AgentChannelInboundActivityEvent,
        timedOutWaitingForMore: Bool = false
    ) {
        let label = AgentChannelInboundActivityPresentation.label(for: event.stage)
        var details: [String] = []
        if let guidance = AgentChannelInboundActivityPresentation.guidance(
            stage: event.stage,
            reason: event.reason
        ) {
            details.append(guidance)
        }
        let isError: Bool
        switch event.stage {
        case .rejected, .dispatchSuppressed, .failed:
            isError = true
        case .received, .stored, .dispatched, .agentReplied, .replySent:
            isError = timedOutWaitingForMore
        }
        if timedOutWaitingForMore {
            details.append(
                L("The message stopped at this stage before the wait expired; check the recent events list above.")
            )
        }
        if !isError {
            verifySucceeded = true
        }
        showStatus(label, details: details, isError: isError)
    }

    private func showDiagnostics(
        _ diagnostics: WhatsAppConnectionDiagnostics,
        presentation suppliedPresentation: AgentChannelStatusPresentation? = nil
    ) {
        let presentation = suppliedPresentation
            ?? AgentChannelStatusPresentation.diagnostics(status: diagnostics.status)
        showStatus(
            presentation.label,
            details: diagnostics.failures + diagnostics.notes,
            isError: !diagnostics.failures.isEmpty || presentation.tone == .error
        )
    }

    // MARK: - Status helpers

    private func showStatus(
        _ message: String,
        details: [String] = [],
        isError: Bool,
        section: AgentChannelProviderSetupSection? = nil
    ) {
        statusMessage = message
        statusDetails = details
        statusIsError = isError
        if isError, let section {
            attentionSectionId = section.rawValue
            withAnimation(theme.motion.quick) {
                selectedSectionId = section.rawValue
            }
        } else if !isError {
            attentionSectionId = nil
        }
    }

    private func clearStatus() {
        statusMessage = nil
        statusDetails = []
    }

    private func parseIds(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n\t")
        return WhatsAppConnectionConfiguration.normalizedIds(
            text.components(separatedBy: separators)
        )
    }

    private func toggledIdText(_ text: String, id: String) -> String {
        var ids = parseIds(text)
        if let index = ids.firstIndex(of: id) {
            ids.remove(at: index)
        } else {
            ids.append(id)
        }
        return ids.joined(separator: "\n")
    }
}
