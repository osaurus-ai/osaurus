//
//  N8nSettingsView.swift
//  osaurus
//
//  Guided setup sheet for the `n8n` Agent Channel kind: a secret-verified
//  inbound webhook with pollable replies and an optional HMAC-signed push
//  back to an n8n Webhook trigger. n8n connections are stored rows, so the
//  sheet creates or edits one `AgentChannelConnection` with an `n8n` block.
//
//  Five steps in the order a first-time operator thinks: Name it → Where is
//  your n8n? → Who answers? → Pair → Prove it. The location step owns its
//  consequences (Relay, encryption, which URLs the pairing code carries),
//  the pairing code is only issued once it can actually work, and the
//  allowlists fill by approving the first workflow that calls in.
//

import SwiftUI

#if os(macOS)
    import AppKit
#endif

struct N8nSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
    /// Relay status feeds the pairing code's public URL candidate.
    @ObservedObject private var relayManager = RelayTunnelManager.shared
    @Environment(\.dismiss) private var dismiss

    /// Existing connection to edit, or nil to create a new one.
    let connection: AgentChannelConnection?
    /// Set when this sheet is hosted inside the unified Add Channel picker;
    /// shows a back chevron that returns to the catalog.
    var onBack: (() -> Void)? = nil
    /// Called after any successful save or delete so the channel list refreshes.
    let onDidChange: () -> Void

    @State private var draft = N8nConnectionDraft()
    @State private var pendingSecret = ""
    @State private var secretSaved = false
    /// Keychain copy of the saved secret, read on appear so the pairing code
    /// can be issued for an existing connection without retyping it.
    @State private var savedSecretValue: String?
    /// LAN address candidate for the pairing code; only used when exposed.
    @State private var lanAddress: String?
    @State private var statusMessage: String?
    @State private var statusDetails: [String] = []
    @State private var statusIsError = false
    @State private var isSaving = false
    @State private var isVerifying = false
    @State private var isDiagnosing = false
    @State private var diagnosticsText: String?
    @State private var showDeleteConfirmation = false
    @State private var showShareSheet = false
    @State private var showRelayConfirmation = false
    @State private var healthRefreshToken = 0
    @State private var activityRefreshToken = 0
    @State private var selectedSectionId: String = N8nSetupSection.basics.rawValue
    @State private var attentionSectionId: String?
    @State private var verifySucceeded = false
    /// Snapshot of the server binding used for the URL card, read on appear.
    @State private var serverPort = ServerConfiguration.default.port
    @State private var serverExposedToNetwork = false
    /// Master write toggle from Connection Center; push fails while this is off.
    @State private var globalWritesEnabled = true
    /// Workflows that called in with an identity not approved yet.
    @State private var pendingContacts: [AgentChannelN8nPendingContact] = []

    private let manager = AgentChannelConnectionManager.shared
    private let service = AgentChannelConnectionService.shared
    private let pendingCenter = AgentChannelN8nPendingContactCenter.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        AgentChannelSetupScaffold(
            icon: AgentChannelKind.n8n.icon,
            gradient: AgentChannelKind.n8n.brandGradient,
            title: draft.isNew ? L("New n8n Channel") : (draft.name.isEmpty ? draft.id : draft.name),
            subtitle: L("n8n HTTP Request in, poll or webhook out"),
            sections: N8nSetupSection.sections,
            selection: $selectedSectionId,
            sectionStatus: sectionStatus(for:),
            onBack: onBack
        ) { sectionId in
            VStack(alignment: .leading, spacing: 20) {
                switch N8nSetupSection(rawValue: sectionId) {
                case .basics:
                    basicsSectionContent
                case .location:
                    locationSectionContent
                case .howOsaurusReplies:
                    replySectionContent
                case .connect:
                    connectSectionContent
                case .liveCheck, nil:
                    liveSectionContent
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
                title: canRunLiveDiagnostics ? L("Run Diagnostics") : L("Check Configuration"),
                busyTitle: L("Diagnosing..."),
                isBusy: isDiagnosing,
                action: diagnose
            )
            .disabled(isDiagnosing || trimmedDraftId.isEmpty)

            if !draft.isNew {
                AgentChannelSheetActionButton(
                    title: L("Delete"),
                    busyTitle: L("Delete"),
                    isBusy: false,
                    isDestructive: true,
                    action: { showDeleteConfirmation = true }
                )
            }
        } footerTrailing: {
            AgentChannelSheetActionButton(
                title: L("Save"),
                busyTitle: L("Saving..."),
                isBusy: isSaving,
                isPrimary: true,
                action: saveDraft
            )
            .disabled(isSaving || trimmedDraftId.isEmpty)
        }
        .onAppear(perform: load)
        .onChange(of: draft.name) { _, newName in
            // Name-first: the id follows the display name until the operator
            // edits the id by hand or the connection is saved.
            guard draft.isNew, !draft.idWasEdited else { return }
            draft.id = N8nConnectionSlug.make(from: newName)
        }
        .onChange(of: draft.id) { _, newId in
            guard draft.isNew, !draft.idWasEdited else { return }
            if newId != N8nConnectionSlug.make(from: draft.name) {
                draft.idWasEdited = true
            }
        }
        .onChange(of: draft.callerLocation) { _, location in
            // The location owns the plaintext decision: only a LAN caller
            // ever needs plaintext from another machine.
            if location != .lan { draft.plaintextAllowed = false }
        }
        .onReceive(
            NotificationCenter.default
                .publisher(for: .agentChannelN8nPendingContactsChanged)
                .receive(on: DispatchQueue.main)
        ) { _ in
            reloadPendingContacts()
        }
        .themedAlert(
            L("Delete Connection?"),
            isPresented: $showDeleteConfirmation,
            message: L(
                "This removes the \"\(draft.id)\" n8n channel from the configuration file. The Keychain secret it references is not deleted."
            ),
            primaryButton: .destructive(L("Delete")) { performDelete() },
            secondaryButton: .cancel(L("Cancel")),
            presentationStyle: .contained
        )
        .themedAlert(
            L("Expose \(shareableAgent?.name ?? L("this agent")) to the Internet?"),
            isPresented: $showRelayConfirmation,
            message: L(
                "Relay gives this agent a public URL via agent.osaurus.ai so your hosted n8n can reach it. The pairing code pins the agent, so n8n traffic through the relay is end-to-end encrypted; the relay only sees ciphertext."
            ),
            primaryButton: .destructive(L("Enable Relay")) { enableRelayOnBoundAgent() },
            secondaryButton: .cancel(L("Cancel")),
            presentationStyle: .contained
        )
        .sheet(isPresented: $showShareSheet) {
            if let agent = shareableAgent {
                ShareAgentSheet(agent: agent)
                    .environment(\.theme, themeManager.currentTheme)
            }
        }
    }

    // MARK: - Derived state

    private var trimmedDraftId: String {
        AgentChannelConnection.normalizedId(draft.id)
    }

    /// Live diagnostics need the saved connection under its current id;
    /// otherwise the button performs a local draft check instead.
    private var canRunLiveDiagnostics: Bool {
        guard let originalId = draft.originalId else { return false }
        return trimmedDraftId == originalId
    }

    private var hasSecret: Bool {
        secretSaved || !pendingSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var allowedConversations: [String] {
        N8nConnectionDraft.parseList(draft.conversationAllowlistText)
    }

    private var allowedSenders: [String] {
        N8nConnectionDraft.parseList(draft.senderAllowlistText)
    }

    private var routableRooms: [AgentChannelRoutableRoom] {
        allowedConversations.map { AgentChannelRoutableRoom(id: $0, name: $0) }
    }

    /// Local agent the Secure Channel invite is scoped to: the default
    /// dispatch target when it is a local agent.
    private var shareableAgent: Agent? {
        guard let localId = draft.inboundTarget?.localId else { return nil }
        return agentManager.agents.first { $0.id == localId }
    }

    private var channelDisplayName: String {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return trimmedDraftId.isEmpty ? L("this channel") : trimmedDraftId
    }

    private var effectiveLocation: AgentChannelN8nCallerLocation {
        draft.callerLocation ?? .thisMac
    }

    private var inboundURL: String {
        N8nSetupRecipe.inboundURL(
            connectionId: displayId,
            port: serverPort,
            location: effectiveLocation,
            relayURL: relayURLForPairing
        )
    }

    private var pollURLTemplate: String {
        N8nSetupRecipe.pollURL(
            connectionId: displayId,
            port: serverPort,
            location: effectiveLocation,
            relayURL: relayURLForPairing
        )
    }

    private var displayId: String {
        trimmedDraftId.isEmpty ? "<connection-id>" : trimmedDraftId
    }

    private var sampleEnvelope: String {
        N8nSetupRecipe.sampleEnvelope(
            conversationId: allowedConversations.first ?? "n8n-test",
            senderId: allowedSenders.first ?? "workflow"
        )
    }

    private var httpRequestRecipe: String {
        N8nSetupRecipe.httpRequestRecipe(
            inboundURL: inboundURL,
            headerName: effectiveHeaderName,
            method: draft.verificationMethod
        )
    }

    private var wantsOutboundPush: Bool {
        !draft.outboundWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var pushBlockedByKillSwitch: Bool {
        wantsOutboundPush && draft.inboundAutoReplyEnabled && !globalWritesEnabled
    }

    private var effectiveHeaderName: String {
        draft.verification.effectiveHeaderName
    }

    // MARK: - Relay

    private var boundAgentRelayStatus: AgentRelayStatus? {
        guard let agent = shareableAgent else { return nil }
        return relayManager.agentStatuses[agent.id] ?? .disconnected
    }

    /// Public relay URL for the agent bound in Who answers?, once the relay
    /// reports the route is live.
    private var relayURLForPairing: String? {
        guard case .connected(let url)? = boundAgentRelayStatus else { return nil }
        return url
    }

    // MARK: - Pairing code

    /// The secret the pairing code carries: the value being typed, else the
    /// Keychain copy of the saved one.
    private var pairingSecret: String? {
        let typed = pendingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return savedSecretValue
    }

    private var pairingReachability: N8nPairingCode.Reachability {
        N8nPairingCode.Reachability(
            port: serverPort,
            callerLocation: effectiveLocation,
            exposedToNetwork: serverExposedToNetwork,
            lanAddress: lanAddress,
            relayURL: relayURLForPairing,
            agentAddress: shareableAgent?.agentAddress,
            plaintextAllowed: draft.plaintextAllowed
        )
    }

    private var pairingReadiness: N8nPairingCode.Readiness {
        N8nPairingCode.readiness(pairingReachability)
    }

    private var pairingCode: N8nPairingCode? {
        guard !trimmedDraftId.isEmpty, let secret = pairingSecret, pairingReadiness == .ready else { return nil }
        return N8nPairingCode.make(
            connectionId: trimmedDraftId,
            name: draft.name,
            secret: secret,
            verification: draft.verification,
            reachability: pairingReachability
        )
    }

    // MARK: - Section state

    private func sectionCompleted(_ sectionId: String) -> Bool {
        switch N8nSetupSection(rawValue: sectionId) {
        case .basics:
            return !trimmedDraftId.isEmpty
        case .location:
            return draft.callerLocation != nil
        case .howOsaurusReplies:
            guard draft.inboundDispatchEnabled else { return false }
            if draft.callerLocation == .remote { return shareableAgent != nil }
            return draft.inboundTarget != nil || !draft.inboundRoutes.isEmpty
        case .connect:
            return hasSecret && pairingReadiness == .ready
        case .liveCheck:
            return verifySucceeded
        case nil:
            return false
        }
    }

    private func sectionStatus(for sectionId: String) -> AgentChannelSetupSectionStatus {
        if attentionSectionId == sectionId { return .attention }
        return sectionCompleted(sectionId) ? .complete : .pending
    }

    private func jump(to section: N8nSetupSection) {
        withAnimation(.easeOut(duration: 0.15)) {
            selectedSectionId = section.rawValue
        }
    }

    // MARK: - 1. Name it

    private var basicsSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            orientationCard
            identitySection
        }
    }

    /// The one sentence that answers "where do I enter my n8n URL?".
    private var orientationCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.left.arrow.right.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.accentColor)
                .padding(.top, 1)
            Text(
                "n8n connects to Osaurus, not the other way around. At the end you copy one pairing code into n8n — that is the whole hand-off. You only enter an n8n URL if you want Osaurus to push replies to a workflow.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.accentColor.opacity(0.07))
        )
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(
                L("Name it"),
                detail: L("A name you will recognize in the channel list. The id below follows it and appears in the webhook URL.")
            )

            StyledSettingsTextField(
                label: L("Display Name"),
                text: $draft.name,
                placeholder: L("Accounting Channel"),
                help: L("Human-readable name shown in the channel list and in n8n's credential.")
            )

            StyledSettingsTextField(
                label: L("Connection ID"),
                text: $draft.id,
                placeholder: "n8n-accounting-channel",
                help: draft.isNew
                    ? L("Filled from the name; edit if you like. Lowercase letters, digits and dashes. Locked after Save.")
                    : L("Stable id used in the webhook URL and by agent_channel tools. Cannot change after Save.")
            )
            .disabled(!draft.isNew)
        }
    }

    // MARK: - 2. Where is your n8n?

    private var locationSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                AgentChannelSectionHeading(
                    L("Where is your n8n?"),
                    detail: L(
                        "This decides which URL the pairing code carries, whether n8n needs Relay to reach this Mac, and whether the connection is end-to-end encrypted."
                    )
                )

                if draft.callerLocation == nil, !draft.isNew {
                    consequenceRow(
                        icon: "questionmark.circle.fill",
                        tone: .warning,
                        text: L(
                            "This channel was saved before Osaurus asked where n8n runs. Pick it once so the pairing code carries the right URL; your existing n8n credential keeps working meanwhile."
                        )
                    )
                }

                VStack(spacing: 8) {
                    ForEach(AgentChannelN8nCallerLocation.allCases, id: \.self) { location in
                        locationChoice(location)
                    }
                }
                .settingsLandingAnchor("agentChannels.n8n.callerLocation")
            }

            if let location = draft.callerLocation {
                SettingsDivider()
                locationConsequences(location)
            }
        }
    }

    private func locationChoice(_ location: AgentChannelN8nCallerLocation) -> some View {
        let selected = draft.callerLocation == location
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                draft.callerLocation = location
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundColor(selected ? theme.accentColor : theme.tertiaryText)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(location.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Text(location.summary)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? theme.accentColor.opacity(0.08) : theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(selected ? theme.accentColor.opacity(0.5) : theme.cardBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private func locationConsequences(_ location: AgentChannelN8nCallerLocation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("What this means"))

            switch location {
            case .thisMac:
                consequenceRow(icon: "lock.fill", tone: .neutral, text: L("Pairing code URL: http://127.0.0.1:\(serverPort)"))
                consequenceRow(
                    icon: "checkmark.shield",
                    tone: .success,
                    text: L("Loopback traffic never leaves this Mac. Encryption is optional; binding a local agent in Who answers? adds it.")
                )
            case .dockerDesktop:
                consequenceRow(
                    icon: "lock.fill",
                    tone: .neutral,
                    text: L("Pairing code URL: http://host.docker.internal:\(serverPort)")
                )
                consequenceRow(
                    icon: "checkmark.shield",
                    tone: .success,
                    text: L("Docker Desktop forwards the container's request from 127.0.0.1, so it counts as this Mac.")
                )
            case .lan:
                consequenceRow(
                    icon: serverExposedToNetwork ? "network" : "network.slash",
                    tone: serverExposedToNetwork ? .success : .warning,
                    text: serverExposedToNetwork
                        ? L("Server is exposed to the network. Pairing code URL: http://\(lanAddress ?? "<this-mac-ip>"):\(serverPort)")
                        : L("The server is not exposed to the network yet. Turn on Expose to Network in Server settings, then come back.")
                )
                consequenceRow(
                    icon: shareableAgent != nil ? "lock.shield" : "lock.open",
                    tone: shareableAgent != nil ? .success : .neutral,
                    text: shareableAgent != nil
                        ? L("A local agent is bound, so n8n speaks Secure Channel and plaintext is never needed.")
                        : L("Without a bound agent, another machine can only reach this channel over plaintext HTTP. Bind a local agent in Who answers?, or allow plaintext below.")
                )
                transportPolicySection
            case .remote:
                consequenceRow(
                    icon: "globe",
                    tone: .neutral,
                    text: L("n8n reaches this Mac through the Osaurus relay. No ports to open, no plaintext from the internet.")
                )
                consequenceRow(
                    icon: "lock.shield",
                    tone: .success,
                    text: L("Requires a local agent in Who answers? with Relay enabled. The pairing code carries only the relay URL and is end-to-end encrypted.")
                )
                if shareableAgent == nil {
                    jumpButton(L("Choose the agent in Who answers?"), to: .howOsaurusReplies)
                } else if relayURLForPairing == nil {
                    jumpButton(L("Enable Relay on \(shareableAgent?.name ?? "") in Who answers?"), to: .howOsaurusReplies)
                }
            }
        }
    }

    private enum ConsequenceTone { case neutral, success, warning }

    private func consequenceRow(icon: String, tone: ConsequenceTone, text: String) -> some View {
        let color: Color
        switch tone {
        case .neutral: color = theme.tertiaryText
        case .success: color = theme.successColor
        case .warning: color = theme.warningColor
        }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(color)
                .frame(width: 14)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(tone == .warning ? theme.warningColor : theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func jumpButton(_ title: String, to section: N8nSetupSection) -> some View {
        Button {
            jump(to: section)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(theme.accentColor)
        }
        .buttonStyle(PlainButtonStyle())
    }

    /// Only meaningful for LAN callers. Remote uses Secure Channel; This Mac
    /// and Docker Desktop are loopback.
    private var transportPolicySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsToggle(
                title: L("Allow plaintext HTTP from other machines"),
                description: L(
                    "Off: callers not on this Mac must use Secure Channel or get 426. On: the secret alone is enough — trusted LAN only."
                ),
                isOn: $draft.plaintextAllowed
            )
            .settingsLandingAnchor("agentChannels.n8n.plaintextAllowed")

            if draft.plaintextAllowed {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.warningColor)
                        .padding(.top, 1)
                    Text(
                        "Anyone who can reach this port and knows the secret can send events and read replies for this connection.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.warningColor.opacity(0.08))
                )
            }
        }
    }

    // MARK: - 3. Who answers?

    private var replySectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            dispatchSection
            if draft.callerLocation == .remote || (draft.callerLocation == .lan && shareableAgent != nil) {
                SettingsDivider()
                relaySection
            }
            SettingsDivider()
            outboundSection
        }
    }

    private var dispatchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(
                L("Who answers?"),
                detail: L(
                    "The agent that replies to verified events. It also decides more than its name: a local agent makes the pairing code end-to-end encrypted, and with Relay it is what a remote n8n reaches."
                )
            )

            SettingsToggle(
                title: L("Reply with an Agent"),
                description: L(
                    "Each conversation gets its own private session; external-surface tool restrictions apply."
                ),
                isOn: $draft.inboundDispatchEnabled.animation(.easeOut(duration: 0.2))
            )

            if draft.inboundDispatchEnabled {
                AgentChannelDispatchRoutingEditor(
                    roomNoun: L("conversation"),
                    rooms: routableRooms,
                    defaultTarget: $draft.inboundTarget,
                    routes: $draft.inboundRoutes
                )
                AgentChannelPluginPreloadOverflowNotice(agentId: draft.inboundTarget?.localId)

                if draft.callerLocation == .remote, shareableAgent == nil {
                    consequenceRow(
                        icon: "exclamationmark.triangle.fill",
                        tone: .warning,
                        text: L("Remote n8n needs a local agent as the default: it is the endpoint the relay serves and the key n8n encrypts to.")
                    )
                } else {
                    Text(
                        shareableAgent != nil
                            ? L("n8n reads the reply by polling. The default agent is local, so the pairing code is end-to-end encrypted.")
                            : L("n8n reads the reply by polling. Pick a local agent as the default to make the pairing code end-to-end encrypted.")
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Relay control for the bound agent, right where the choice is made, so
    /// a remote setup never requires a detour through another settings pane.
    private var relaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(
                L("Relay for \(shareableAgent?.name ?? L("the bound agent"))"),
                detail: draft.callerLocation == .remote
                    ? L("Gives the agent a public URL via agent.osaurus.ai. The pairing code is issued once the relay is connected.")
                    : L("Optional for LAN: with Relay on, the same pairing code also works when n8n moves off your network.")
            )
            .settingsLandingAnchor("agentChannels.n8n.relay")

            switch boundAgentRelayStatus {
            case .connected(let url)?:
                consequenceRow(icon: "checkmark.circle.fill", tone: .success, text: L("Relay connected — \(url)"))
            case .connecting?:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting Relay… the pairing code appears in Pair when it is live.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.secondaryText)
                }
            case .error(let message)?:
                consequenceRow(icon: "xmark.octagon.fill", tone: .warning, text: L("Relay error: \(message)"))
                relayEnableButton(title: L("Retry Relay"))
            case .servedElsewhere?:
                consequenceRow(
                    icon: "exclamationmark.triangle.fill",
                    tone: .warning,
                    text: L("Another device is serving this agent's address on the relay. Re-enable here to take it back.")
                )
                relayEnableButton(title: L("Take over Relay on \(shareableAgent?.name ?? "")"))
            case .disconnected?, nil:
                relayEnableButton(title: L("Enable Relay on \(shareableAgent?.name ?? "")"))
            }
        }
    }

    private func relayEnableButton(title: String) -> some View {
        Button {
            showRelayConfirmation = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.accentColor)
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(shareableAgent == nil)
    }

    private var outboundSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pushBlockedByKillSwitch {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.warningColor)
                        .padding(.top, 1)
                    Text(
                        "Push will fail until Allow Agents to Send Messages is on in Connection Center. Poll still returns the reply.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.warningColor.opacity(0.08))
                )
            }

            AgentChannelSectionHeading(
                L("Push replies to n8n (optional)"),
                detail: L(
                    "The only place an n8n URL belongs. Also POST the reply as a signed envelope to an Osaurus Trigger or Webhook node. Needs a public https:// URL; loopback, private ranges and plain http are refused. Polling already returns every reply."
                )
            )

            StyledSettingsTextField(
                label: L("Outbound Webhook URL"),
                text: $draft.outboundWebhookURL,
                placeholder: "https://n8n.example.com/webhook/osaurus-reply",
                help: L("Leave empty to keep replies poll-only.")
            )
            .settingsLandingAnchor("agentChannels.n8n.outboundWebhookURL")

            if !draft.outboundWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                SettingsToggle(
                    title: L("Sign Outbound Bodies"),
                    description: L(
                        "Adds X-Osaurus-Channel-Signature: sha256=<HMAC of the body> using the channel secret so the workflow can verify Osaurus."
                    ),
                    isOn: $draft.outboundSignBodies
                )
                SettingsToggle(
                    title: L("Reply Automatically"),
                    description: L(
                        "Push the selected agent's sanitized reply as soon as it finishes. Global writes and the conversation allowlist still apply."
                    ),
                    isOn: $draft.inboundAutoReplyEnabled
                )
                if !draft.inboundAutoReplyEnabled {
                    AgentChannelAutoReplyOffNotice()
                }
            }
        }
    }

    // MARK: - 4. Pair

    private var connectSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(
                "Install the @osaurus/n8n-nodes-osaurus community node in n8n, then paste this one pairing code into its Osaurus Channel credential and press Test.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            pairingSection
            SettingsDivider()
            AgentChannelAdvancedSection {
                VStack(alignment: .leading, spacing: 20) {
                    secretSection
                    SettingsDivider()
                    verificationSection
                    SettingsDivider()
                    manualRecipeContent
                }
            }
        }
    }

    private var pairingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(
                L("Pair with n8n"),
                detail: L(
                    "The code carries the one URL that reaches this Mac from where your n8n runs, the connection id, the secret, and the verification method — treat it like the secret."
                )
            )

            if let pairingCode {
                let encoded = pairingCode.encoded()
                AgentChannelCopyableCommand(
                    command: encoded,
                    caption: pairingCode.isEndToEndEncrypted
                        ? L("End-to-end encrypted via Secure Channel") : L("Plaintext HTTP"),
                    onCopied: { showStatus(L("Pairing code copied"), isError: false) }
                )

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(pairingCode.urls, id: \.self) { url in
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.turn.down.right")
                                .font(.system(size: 9))
                                .foregroundColor(theme.tertiaryText)
                            Text(url)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(theme.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Text(
                        "Scoped to \(effectiveLocation.title). Change Where is your n8n? and copy the code again if n8n moves.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                }

                if !draft.isNew, secretSaved, pendingSecret.isEmpty == false {
                    pairingHint(L("This code uses the new secret. Save, then re-paste it into n8n."))
                }
            } else if trimmedDraftId.isEmpty {
                pairingHint(L("Name the channel first and the pairing code appears here."))
                jumpButton(L("Go to Name it"), to: .basics)
            } else if draft.callerLocation == nil {
                pairingHint(L("Say where your n8n runs and the pairing code appears here."))
                jumpButton(L("Go to Where is your n8n?"), to: .location)
            } else if !hasSecret {
                pairingHint(L("Generate a channel secret under Advanced and the pairing code appears here."))
            } else if let blocker = pairingReadiness.blocker {
                blockerCard(blocker)
            }
        }
        .settingsLandingAnchor("agentChannels.n8n.pairingCode")
    }

    /// Why no code is offered yet, and the one step that unblocks it.
    private func blockerCard(_ blocker: N8nPairingCode.Blocker) -> some View {
        let message: String
        let action: (title: String, section: N8nSetupSection)
        switch blocker {
        case .needsBoundAgent:
            message = L(
                "No pairing code yet: a remote n8n needs a local agent. The code would carry no URL that can reach this Mac from the internet."
            )
            action = (L("Choose the agent in Who answers?"), .howOsaurusReplies)
        case .needsRelay:
            message = L(
                "No pairing code yet: Relay on \(shareableAgent?.name ?? L("the bound agent")) is not connected, so there is no public URL to put in it. Enable Relay, wait for it to connect, then come back."
            )
            action = (L("Enable Relay in Who answers?"), .howOsaurusReplies)
        case .needsExposeToNetwork:
            message = L(
                "No pairing code yet: the server is not exposed to the network, so another machine has no address to reach. Turn on Expose to Network in Server settings, then reopen this sheet."
            )
            action = (L("Review Where is your n8n?"), .location)
        case .needsPlaintextOrAgent:
            message = L(
                "No pairing code yet: another machine would be refused with 426. Bind a local agent in Who answers? for Secure Channel, or allow plaintext HTTP in Where is your n8n?."
            )
            action = (L("Review Where is your n8n?"), .location)
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.warningColor)
                    .padding(.top, 1)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundColor(theme.warningColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            jumpButton(action.title, to: action.section)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.warningColor.opacity(0.08))
        )
    }

    private func pairingHint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var secretSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(
                L("Channel secret"),
                detail: L(
                    "Generated for you. Every request from n8n must prove it. It travels inside the pairing code and is saved to the macOS Keychain when you press Save."
                )
            )

            AgentChannelSecretField(
                label: L("Channel Secret"),
                requirementHint: L("Required"),
                placeholder: L("32+ random characters"),
                text: $pendingSecret,
                saved: secretSaved,
                onRemove: removeSecret
            )
            .settingsLandingAnchor("agentChannels.n8n.channelSecret")

            HStack(spacing: 8) {
                Button(action: generateSecret) {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 10))
                        Text(secretSaved ? L("Rotate") : L("Generate"))
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
                .help(L("Fill the field with a random 48-character secret"))

                if secretSaved {
                    Text("Rotating changes the pairing code; re-paste it into n8n.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }
        }
    }

    private var verificationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Verification", bundle: .module)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
            Picker(selection: $draft.verificationMethod) {
                Text("HMAC-SHA256 signature", bundle: .module).tag(AgentChannelSourceVerificationMethod.hmacSHA256)
                Text("Shared secret header", bundle: .module).tag(
                    AgentChannelSourceVerificationMethod.sharedSecretHeader
                )
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text(verificationHelp)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

            StyledSettingsTextField(
                label: L("Header Name"),
                text: $draft.verificationHeaderName,
                placeholder: draft.verification.effectiveHeaderName,
                help: L("Override the header n8n sends the secret or signature in. Leave empty for the default.")
            )
        }
    }

    /// Everything a workflow needs when it does not use the Osaurus node:
    /// raw URLs for the chosen location, copyable HTTP Request / HMAC / curl
    /// fragments, and the osk-v1 key for the Agent resource.
    private var manualRecipeContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                AgentChannelSectionHeading(
                    L("Without the Osaurus node"),
                    detail: L(
                        "For a plain HTTP Request node: POST the envelope to the inbound URL, then GET the poll_url from the 202 until status is completed. URLs follow Where is your n8n?."
                    )
                )

                AgentChannelCopyableCommand(
                    command: "POST \(inboundURL)",
                    caption: L("Inbound"),
                    onCopied: { showStatus(L("Inbound URL copied"), isError: false) }
                )
                AgentChannelCopyableCommand(
                    command: "GET \(pollURLTemplate)",
                    caption: L("Poll (same header)"),
                    onCopied: { showStatus(L("Poll URL copied"), isError: false) }
                )

                Text(locationRecipeHelp)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                AgentChannelCopyableCommand(
                    command: sampleEnvelope,
                    caption: L("Sample envelope"),
                    lineLimit: 4,
                    onCopied: { showStatus(L("Sample envelope copied"), isError: false) }
                )
                AgentChannelCopyableCommand(
                    command: httpRequestRecipe,
                    caption: L("HTTP Request"),
                    lineLimit: 4,
                    onCopied: { showStatus(L("HTTP Request recipe copied"), isError: false) }
                )
                if draft.verificationMethod == .hmacSHA256 {
                    AgentChannelCopyableCommand(
                        command: N8nSetupRecipe.hmacCodeSnippet(),
                        caption: L("HMAC Code node"),
                        lineLimit: 5,
                        onCopied: { showStatus(L("HMAC snippet copied"), isError: false) }
                    )
                }
                AgentChannelCopyableCommand(
                    command: curlExample,
                    caption: L("curl"),
                    lineLimit: 4,
                    onCopied: { showStatus(L("Example copied"), isError: false) }
                )
                Text(
                    "Attachments in the envelope are metadata-only; Osaurus does not fetch the file bytes.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }

            secureChannelSection
        }
    }

    private var locationRecipeHelp: String {
        switch effectiveLocation {
        case .thisMac:
            return L("n8n on this Mac calls 127.0.0.1.")
        case .dockerDesktop:
            return L("Docker Desktop reaches this Mac as host.docker.internal; it counts as a same-Mac caller.")
        case .lan:
            return serverExposedToNetwork
                ? L("Plain HTTP from the LAN needs Allow plaintext HTTP in Where is your n8n?, unless the node speaks Secure Channel.")
                : L("Expose the server to the network in Server settings first.")
        case .remote:
            return L(
                "Plain HTTP Request nodes cannot speak Secure Channel, so from the internet they are refused with 426. Use the Osaurus node with the pairing code."
            )
        }
    }

    private var verificationHelp: String {
        switch draft.verificationMethod {
        case .hmacSHA256:
            return L(
                "n8n sends \(effectiveHeaderName): sha256=<hex HMAC-SHA256 of the exact request body>. Poll requests sign the empty body."
            )
        case .sharedSecretHeader, .none:
            return L(
                "n8n sends the secret verbatim in \(effectiveHeaderName). Simpler, but the secret travels with every request."
            )
        }
    }

    private var secureChannelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(
                L("Access key for the Agent resource"),
                detail: L(
                    "An osk-v1 key lets the node's Agent resource call /agents/…/run or dispatch over Secure Channel. It is not the channel secret above."
                )
            )

            if shareableAgent != nil {
                Button {
                    showShareSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "key.horizontal")
                            .font(.system(size: 10))
                        Text("Generate an access key", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
                .help(L("Issue an agent-scoped osk-v1 key so remote n8n can call this agent end-to-end encrypted."))
            } else {
                Text(
                    "Bind a local agent in Who answers? to issue an access key from here.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 5. Prove it

    private var liveSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            approvalsSection
            SettingsDivider()
            verifySection
            SettingsDivider()
            AgentChannelAdvancedSection {
                VStack(alignment: .leading, spacing: 20) {
                    manualAllowlistSection
                    SettingsDivider()
                    Button(action: revealConfigurationFile) {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 10))
                            Text("Open configuration file", bundle: .module)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(theme.accentColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(L("Show agent-channels.json in Finder"))
                }
            }
        }
    }

    /// Approve-on-first-contact: the workflow's real identifiers arrive with
    /// its first run; the operator recognizes them instead of predicting them.
    private var approvalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(
                L("Who may speak"),
                detail: draft.isNew
                    ? L(
                        "Save, build the workflow in n8n, and run it once. Its conversation and sender ids show up here for you to allow. Nothing reaches the agent before you do."
                    )
                    : L(
                        "Run the workflow once. Its conversation and sender ids show up here for you to allow. Nothing reaches the agent before you do."
                    )
            )
            .settingsLandingAnchor("agentChannels.n8n.pendingApprovals")

            if !pendingContacts.isEmpty {
                VStack(spacing: 8) {
                    ForEach(pendingContacts) { contact in
                        pendingContactRow(contact)
                    }
                }
            }

            if allowedConversations.isEmpty && allowedSenders.isEmpty {
                if pendingContacts.isEmpty {
                    pairingHint(
                        draft.isNew
                            ? L("No workflows approved yet.")
                            : L("No workflows approved yet. Waiting for the first run…")
                    )
                }
            } else {
                approvedChips
            }
        }
    }

    private func pendingContactRow(_ contact: AgentChannelN8nPendingContact) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.warningColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    "Workflow '\(contact.conversationId)' (sender '\(contact.senderId)') wants to use \(channelDisplayName)",
                    bundle: .module
                )
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    contact.eventCount == 1
                        ? L("1 event so far · last event id \(contact.lastEventId)")
                        : L("\(contact.eventCount) events so far · last event id \(contact.lastEventId)")
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                AgentChannelSheetActionButton(
                    title: L("Deny"),
                    busyTitle: L("Deny"),
                    isBusy: false,
                    action: { deny(contact) }
                )
                AgentChannelSheetActionButton(
                    title: L("Allow"),
                    busyTitle: L("Allow"),
                    isBusy: false,
                    isPrimary: true,
                    action: { approve(contact) }
                )
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.warningColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.warningColor.opacity(0.35), lineWidth: 1)
                )
        )
    }

    private var approvedChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            chipGroup(title: L("Allowed conversations"), values: allowedConversations) { value in
                revoke(conversationId: value)
            }
            chipGroup(title: L("Allowed senders"), values: allowedSenders) { value in
                revoke(senderId: value)
            }
        }
    }

    private func chipGroup(title: String, values: [String], onRemove: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
            if values.isEmpty {
                Text("None yet", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            } else {
                FlowChips(values: values, onRemove: onRemove)
            }
        }
    }

    private var verifySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(
                L("Verify an incoming event"),
                detail: draft.isNew
                    ? L("Save the channel first. Then run the n8n workflow and each stage appears here.")
                    : L("Run the n8n workflow (or the curl example under Pair → Advanced) and each stage appears here.")
            )

            if !draft.isNew {
                AgentChannelTransportHealthView(
                    connectionId: draft.id,
                    transportId: AgentChannelWebhookIngress.transportId,
                    title: L("n8n webhook ingress"),
                    notRunningHint: L(
                        "No verified n8n event has arrived this session. Trigger the workflow with the saved secret to start it."
                    ),
                    refreshToken: healthRefreshToken
                )

                AgentChannelInboundActivityListView(
                    connectionId: draft.id,
                    emptyHint: L(
                        "No incoming n8n events yet this session. Trigger the workflow and press “Verify incoming event”."
                    ),
                    refreshToken: activityRefreshToken
                )
            }

            AgentChannelSheetActionButton(
                title: L("Verify incoming event"),
                busyTitle: L("Waiting for an n8n event..."),
                isBusy: isVerifying,
                action: verifyIncomingEvent
            )
            .disabled(isVerifying || isSaving || draft.isNew)

            if let diagnosticsText {
                SettingsDivider()
                AgentChannelSectionHeading(L("Diagnostics"))
                ScrollView {
                    Text(diagnosticsText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.secondaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 180)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(theme.cardBorder, lineWidth: 1)
                        )
                )
            }
        }
    }

    /// Manual allowlist editing for operators who prefer to type ids ahead
    /// of time. Saved with the rest of the draft.
    private var manualAllowlistSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(
                L("Edit allowlists by hand"),
                detail: L(
                    "Fail-closed: the conversation_id and sender.id the workflow sends must each match a line here. Approving a workflow above adds its lines for you."
                )
            )

            HStack(alignment: .top, spacing: 12) {
                AgentChannelMultilineSettingsField(
                    title: L("Allowed Conversations"),
                    text: $draft.conversationAllowlistText,
                    placeholder: L("n8n-test — one per line"),
                    help: L(
                        "conversation_id values the workflow declares. Each one maps to its own agent session."
                    )
                )
                AgentChannelMultilineSettingsField(
                    title: L("Allowed Senders"),
                    text: $draft.senderAllowlistText,
                    placeholder: L("sender-id — one per line"),
                    help: L("sender.id values the workflow declares. Empty denies everyone.")
                )
            }

            SettingsToggle(
                title: L("Accept Bot Senders"),
                description: L("Accept events whose sender.is_bot is true."),
                isOn: $draft.allowBotMessages
            )
        }
    }

    private var curlExample: String {
        N8nSetupRecipe.curlExample(
            inboundURL: inboundURL,
            headerName: effectiveHeaderName,
            method: draft.verificationMethod,
            conversationId: allowedConversations.first ?? "n8n-test",
            senderId: allowedSenders.first ?? "workflow"
        )
    }

    // MARK: - Actions

    private func load() {
        let configuration = ServerConfigurationStore.load() ?? ServerConfiguration.default
        serverPort = configuration.port
        serverExposedToNetwork = configuration.exposeToNetwork
        globalWritesEnabled = ChannelWriteKillSwitch.shared.snapshot().writeEnabled
        if configuration.exposeToNetwork {
            Task.detached {
                let address = LocalNetworkAddress.primaryIPv4()
                await MainActor.run { lanAddress = address }
            }
        }
        if let connection {
            draft = N8nConnectionDraft(connection: connection)
            let pluginId = draft.keychainPluginId
            let secretName = draft.secretName
            Task.detached {
                // One Keychain read serves both the "saved" badge and the
                // pairing code, which needs the secret bytes.
                let value = ToolSecretsKeychain.getSecret(id: secretName, for: pluginId, agentId: Agent.defaultId)
                await MainActor.run {
                    secretSaved = value != nil
                    savedSecretValue = value
                }
            }
            reloadPendingContacts()
        } else if pendingSecret.isEmpty {
            // A new channel always needs a fresh random secret, so issue one
            // silently: the pairing code is then ready as soon as the id is.
            pendingSecret = Self.randomSecret()
        }
        selectedSectionId = AgentChannelSetupFlow.initialSection(
            in: N8nSetupSection.sections,
            required: N8nSetupSection.requiredSectionIds,
            isComplete: { sectionCompleted($0) },
            fallback: N8nSetupSection.fallbackSectionId
        )
    }

    private func reloadPendingContacts() {
        guard let originalId = draft.originalId else {
            pendingContacts = []
            return
        }
        Task {
            let rows = await pendingCenter.pending(connectionId: originalId)
            await MainActor.run { pendingContacts = rows }
        }
    }

    private static func randomSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 36)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func generateSecret() {
        pendingSecret = Self.randomSecret()
        showStatus(
            secretSaved
                ? L("New secret ready — Save, then paste the new pairing code into n8n")
                : L("Secret generated — the pairing code includes it"),
            isError: false
        )
    }

    private func removeSecret() {
        pendingSecret = ""
        savedSecretValue = nil
        guard secretSaved else { return }
        let pluginId = draft.keychainPluginId
        let secretName = draft.secretName
        secretSaved = false
        Task.detached {
            _ = ToolSecretsKeychain.deleteSecret(id: secretName, for: pluginId, agentId: Agent.defaultId)
        }
        showStatus(
            L("Channel secret removed — inbound requests will be refused until a new one is saved"),
            isError: false
        )
    }

    private func enableRelayOnBoundAgent() {
        guard let agent = shareableAgent else { return }
        relayManager.setTunnelEnabled(true, for: agent.id)
        showStatus(L("Enabling Relay on \(agent.name)… the pairing code appears in Pair once it connects."), isError: false)
    }

    // MARK: Approvals

    private func approve(_ contact: AgentChannelN8nPendingContact) {
        do {
            let updated = try manager.approveN8nContact(
                connectionId: contact.connectionId,
                conversationId: contact.conversationId,
                senderId: contact.senderId
            )
            adoptAllowlists(from: updated)
            Task { await pendingCenter.resolve(contact) }
            onDidChange()
            healthRefreshToken += 1
            showStatus(
                L("Allowed '\(contact.conversationId)' from '\(contact.senderId)'. Run the workflow again — it will reach the agent now."),
                isError: false
            )
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func deny(_ contact: AgentChannelN8nPendingContact) {
        Task { await pendingCenter.deny(contact) }
        showStatus(
            L("Denied '\(contact.conversationId)' from '\(contact.senderId)' for this session. Its events stay rejected."),
            isError: false
        )
    }

    private func revoke(conversationId: String? = nil, senderId: String? = nil) {
        guard let originalId = draft.originalId else {
            // Unsaved draft: just edit the text; Save persists it.
            if let conversationId {
                draft.conversationAllowlistText = allowedConversations.filter { $0 != conversationId }.joined(separator: "\n")
            }
            if let senderId {
                draft.senderAllowlistText = allowedSenders.filter { $0 != senderId }.joined(separator: "\n")
            }
            return
        }
        do {
            let updated = try manager.revokeN8nAllowlistEntry(
                connectionId: originalId,
                conversationId: conversationId,
                senderId: senderId
            )
            adoptAllowlists(from: updated)
            onDidChange()
            showStatus(L("Removed. Events with that id are rejected until you allow it again."), isError: false)
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func adoptAllowlists(from connection: AgentChannelConnection) {
        draft.conversationAllowlistText = connection.inboundAuthorization.roomAllowlist.joined(separator: "\n")
        draft.senderAllowlistText = connection.inboundAuthorization.senderAllowlist.joined(separator: "\n")
    }

    /// First cross-field problem the save would reject, or nil when the
    /// draft is persistable.
    private func validationFailure() -> (message: String, section: N8nSetupSection)? {
        if trimmedDraftId.isEmpty {
            return (L("Give the channel a name."), .basics)
        }
        if draft.callerLocation == nil {
            return (L("Say where your n8n runs."), .location)
        }
        if !hasSecret {
            return (L("Generate the channel secret under Pair → Advanced before saving."), .connect)
        }
        if draft.inboundDispatchEnabled, draft.inboundTarget == nil, draft.inboundRoutes.isEmpty {
            return (L("Choose an agent to reply with, or turn off Reply with an Agent."), .howOsaurusReplies)
        }
        // Remote without a local agent is *not* a save error: the draft is
        // persistable, it just cannot pair yet. `saveDraft` reports that as
        // the pairing blocker and jumps to Pair, and Who answers? shows the
        // inline warning, so the user is never stuck on Save.
        let outbound = draft.outboundWebhookURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !outbound.isEmpty,
            AgentChannelN8nPreset.splitWebhookURL(outbound)?.baseURL.hasPrefix("https://") != true
        {
            return (L("The outbound webhook URL must be an absolute https:// URL."), .howOsaurusReplies)
        }
        return nil
    }

    private func saveDraft() {
        if let failure = validationFailure() {
            attentionSectionId = failure.section.rawValue
            jump(to: failure.section)
            showStatus(failure.message, isError: true)
            return
        }
        isSaving = true
        let connection = draft.connection()
        let secret = pendingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let pluginId = N8nConnectionDraft.keychainPluginId(for: connection.id)
        let secretName = connection.n8n?.secretName ?? AgentChannelN8nConfiguration.defaultSecretName
        let originalId = draft.originalId
        let pairingBlocked = pairingReadiness.blocker != nil
        Task {
            var secretStored = true
            if !secret.isEmpty {
                secretStored = await Task.detached {
                    ToolSecretsKeychain.saveSecret(secret, id: secretName, for: pluginId, agentId: Agent.defaultId)
                }.value
            }
            await MainActor.run {
                isSaving = false
                guard secretStored else {
                    attentionSectionId = N8nSetupSection.connect.rawValue
                    showStatus(L("Could not store the channel secret in the Keychain."), isError: true)
                    return
                }
                do {
                    try manager.upsertConnection(connection, replacingOriginalId: originalId)
                    if !secret.isEmpty {
                        secretSaved = true
                        savedSecretValue = secret
                        pendingSecret = ""
                    }
                    draft.originalId = connection.id
                    draft.id = connection.id
                    attentionSectionId = nil
                    healthRefreshToken += 1
                    _ = ToastManager.shared.success(L("n8n channel saved"))
                    onDidChange()
                    Task {
                        await pendingCenter.reconcile(
                            connectionId: connection.id,
                            roomAllowlist: connection.inboundAuthorization.roomAllowlist,
                            senderAllowlist: connection.inboundAuthorization.senderAllowlist
                        )
                    }
                    reloadPendingContacts()
                    if pairingBlocked {
                        showStatus(
                            L("Saved. The pairing code is not ready yet — see Pair for what unblocks it."),
                            isError: false
                        )
                        jump(to: .connect)
                    } else {
                        showStatus(L("Saved. Paste the pairing code into n8n, run the workflow, then allow it below."), isError: false)
                        jump(to: .liveCheck)
                    }
                } catch {
                    let section: N8nSetupSection
                    if case AgentChannelConnectionManagerError.invalidN8nOutboundURL = error {
                        section = .howOsaurusReplies
                    } else {
                        section = .basics
                    }
                    attentionSectionId = section.rawValue
                    jump(to: section)
                    showStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func performDelete() {
        do {
            try manager.deleteConnection(id: draft.id)
            Task { await pendingCenter.clear(connectionId: draft.id) }
            _ = ToastManager.shared.success(L("Channel connection deleted"))
            onDidChange()
            dismiss()
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func diagnose() {
        jump(to: .liveCheck)
        guard canRunLiveDiagnostics else {
            if let failure = validationFailure() {
                diagnosticsText = "• \(failure.message)"
                showStatus(L("Draft check found 1 issue"), isError: true)
            } else {
                diagnosticsText = L("Draft configuration looks valid. Save to run live diagnostics.")
                showStatus(L("Draft check passed"), isError: false)
            }
            return
        }
        isDiagnosing = true
        let connectionId = trimmedDraftId
        Task {
            let diagnostics = await service.diagnostics(connectionId: connectionId)
            let rendered = Self.prettyJSON(diagnostics)
            await MainActor.run {
                diagnosticsText = rendered
                isDiagnosing = false
                healthRefreshToken += 1
                if diagnostics["failure"] is String {
                    showStatus(L("Channel diagnostics reported a failure"), isError: true)
                } else {
                    showStatus(L("Channel diagnostics complete"), isError: false)
                }
            }
        }
    }

    private func verifyIncomingEvent() {
        isVerifying = true
        showStatus(
            L("Waiting for an n8n event. Run the workflow now with the current pairing code."),
            isError: false
        )
        let start = Date()
        let autoReply = draft.inboundAutoReplyEnabled && !draft.outboundWebhookURL.isEmpty
        let connectionId = draft.id
        Task {
            let outcome = await AgentChannelInboundVerifier.waitForTerminalEvent(
                connectionId: connectionId,
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
                healthRefreshToken += 1
                reloadPendingContacts()
                if let event = outcome.event {
                    presentVerifyOutcome(event, timedOutWaitingForMore: outcome.timedOutWaitingForMore)
                } else {
                    showStatus(
                        L("No n8n event arrived within 90 seconds."),
                        details: [
                            L("Confirm the n8n credential holds the current pairing code from Pair and its Test passes."),
                            L("If Where is your n8n? changed since you copied the code, copy it again."),
                            L("Once the event arrives, allow the workflow above if it asks."),
                        ],
                        isError: true
                    )
                }
            }
        }
    }

    private func presentVerifyOutcome(
        _ event: AgentChannelInboundActivityEvent,
        timedOutWaitingForMore: Bool
    ) {
        if event.stage == .rejected, event.reason == AgentChannelWebhookIngress.pendingApprovalReason {
            showStatus(
                L("The workflow reached Osaurus and is asking for approval. Press Allow above, then run it again."),
                isError: false
            )
            return
        }
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
                L("The event stopped at this stage before the wait expired; check the recent events list above.")
            )
        }
        if !isError {
            verifySucceeded = true
        }
        showStatus(label, details: details, isError: isError)
    }

    private func revealConfigurationFile() {
        #if os(macOS)
            NSWorkspace.shared.activateFileViewerSelecting([manager.configurationFileURL()])
        #endif
    }

    private func showStatus(_ message: String, details: [String] = [], isError: Bool) {
        statusMessage = message
        statusDetails = details
        statusIsError = isError
        if !isError {
            attentionSectionId = nil
        }
    }

    private func clearStatus() {
        statusMessage = nil
        statusDetails = []
    }

    private static func prettyJSON(_ payload: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys]
            ),
            let string = String(data: data, encoding: .utf8)
        else {
            return String(describing: payload)
        }
        return string
    }
}

// MARK: - Chips

/// Wrapping row of removable id chips for the approved allowlists.
private struct FlowChips: View {
    @ObservedObject private var themeManager = ThemeManager.shared

    let values: [String]
    let onRemove: (String) -> Void

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        // Simple wrap: chips are short ids; a lazy grid keeps layout cheap.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(values, id: \.self) { value in
                HStack(spacing: 6) {
                    Text(value)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        onRemove(value)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(theme.tertiaryText)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(L("Remove \(value) from the allowlist"))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(theme.cardBackground))
                .overlay(Capsule().stroke(theme.cardBorder, lineWidth: 1))
            }
        }
    }
}

// MARK: - Draft

/// Editable projection of an n8n `AgentChannelConnection`. Kept view-agnostic
/// so the round trip (connection -> draft -> connection) is unit-testable.
struct N8nConnectionDraft: Equatable {
    var originalId: String?
    var id = ""
    var name = ""
    /// Set once the operator types in the id field; stops the name → slug
    /// auto-fill. UI-only.
    var idWasEdited = false
    var enabled = true
    var verificationMethod: AgentChannelSourceVerificationMethod = .hmacSHA256
    var verificationHeaderName = ""
    var secretName = AgentChannelN8nConfiguration.defaultSecretName
    var plaintextAllowed = false
    /// nil until the operator answers "Where is your n8n?".
    var callerLocation: AgentChannelN8nCallerLocation?
    var conversationAllowlistText = ""
    var senderAllowlistText = ""
    var allowBotMessages = false
    var inboundDispatchEnabled = false
    var inboundTarget: AgentDispatchTarget?
    var inboundRoutes: [AgentChannelDispatchRoute] = []
    var inboundAutoReplyEnabled = false
    var outboundWebhookURL = ""
    var outboundSignBodies = true

    init() {}

    init(connection: AgentChannelConnection) {
        originalId = connection.id
        id = connection.id
        name = connection.name
        idWasEdited = true
        enabled = connection.enabled
        conversationAllowlistText = connection.inboundAuthorization.roomAllowlist.joined(separator: "\n")
        senderAllowlistText = connection.inboundAuthorization.senderAllowlist.joined(separator: "\n")
        allowBotMessages = connection.inboundAuthorization.allowBotMessages
        let n8n = connection.n8n ?? AgentChannelN8nConfiguration()
        verificationMethod = n8n.inboundVerification.method
        verificationHeaderName = n8n.inboundVerification.headerName ?? ""
        secretName = n8n.secretName
        plaintextAllowed = n8n.remoteTransportPolicy == .plaintextAllowed
        // Only a stored location, or the one unambiguous legacy signal
        // (plaintext is offered for LAN alone), pre-selects the picker. A
        // legacy Secure-Channel row could be This Mac, Docker or Remote, so
        // it stays unanswered and the sheet asks before issuing a code.
        callerLocation = n8n.callerLocation ?? (plaintextAllowed ? .lan : nil)
        inboundDispatchEnabled = n8n.inboundDispatch.enabled
        inboundTarget = n8n.inboundDispatch.target
        inboundRoutes = n8n.inboundDispatch.routes
        inboundAutoReplyEnabled = n8n.inboundDispatch.autoReplyEnabled
        outboundWebhookURL = n8n.outbound.webhookURL ?? ""
        outboundSignBodies = n8n.outbound.signBodies
    }

    var isNew: Bool { originalId == nil }

    var verification: AgentChannelN8nInboundVerification {
        AgentChannelN8nInboundVerification(
            method: verificationMethod,
            headerName: verificationHeaderName
        )
    }

    var keychainPluginId: String {
        Self.keychainPluginId(for: AgentChannelConnection.normalizedId(id))
    }

    static func keychainPluginId(for connectionId: String) -> String {
        "\(KeychainAgentChannelSecretResolver.pluginIdPrefix).\(connectionId)"
    }

    /// Builds the connection the manager stores. The outbound projection onto
    /// `customHTTP` happens inside the manager on save.
    func connection() -> AgentChannelConnection {
        let location = callerLocation ?? .inferred(plaintextAllowed: plaintextAllowed)
        // Only a LAN caller can meaningfully allow plaintext; every other
        // location is loopback or Secure Channel.
        let allowsPlaintext = location == .lan && plaintextAllowed
        let n8n = AgentChannelN8nConfiguration(
            inboundVerification: verification,
            secretName: secretName,
            inboundDispatch: AgentChannelInboundDispatchConfiguration(
                enabled: inboundDispatchEnabled,
                target: inboundTarget,
                routes: inboundRoutes,
                requireMention: false,
                continueThreads: true,
                autoReplyEnabled: inboundAutoReplyEnabled
            ),
            remoteTransportPolicy: allowsPlaintext ? .plaintextAllowed : .secureChannelRequired,
            outbound: AgentChannelN8nOutboundConfiguration(
                webhookURL: outboundWebhookURL,
                signBodies: outboundSignBodies
            ),
            callerLocation: location
        )
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedId = AgentChannelConnection.normalizedId(id)
        return AgentChannelConnection(
            id: normalizedId,
            name: trimmedName.isEmpty ? normalizedId : trimmedName,
            kind: .n8n,
            enabled: enabled,
            supportedActions: [.diagnostics],
            spaceAllowlist: [AgentChannelN8nConfiguration.spaceId],
            inboundAuthorization: AgentChannelInboundAuthorizationPolicy(
                senderAllowlist: Self.parseList(senderAllowlistText),
                roomAllowlist: Self.parseList(conversationAllowlistText),
                allowBotMessages: allowBotMessages
            ),
            n8n: n8n
        )
    }

    static func parseList(_ text: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",\n")
        return AgentChannelConnection.normalizedIds(
            text.components(separatedBy: separators)
        )
    }
}
