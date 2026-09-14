//
//  N8nSettingsView.swift
//  osaurus
//
//  Guided setup sheet for the `n8n` Agent Channel kind: a secret-verified
//  inbound webhook with pollable replies and an optional HMAC-signed push
//  back to an n8n Webhook trigger. n8n connections are stored rows, so the
//  sheet creates or edits one `AgentChannelConnection` with an `n8n` block.
//

import SwiftUI

#if os(macOS)
    import AppKit
#endif

struct N8nSettingsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var agentManager = AgentManager.shared
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
    @State private var statusMessage: String?
    @State private var statusDetails: [String] = []
    @State private var statusIsError = false
    @State private var isSaving = false
    @State private var isVerifying = false
    @State private var isDiagnosing = false
    @State private var diagnosticsText: String?
    @State private var showDeleteConfirmation = false
    @State private var showShareSheet = false
    @State private var healthRefreshToken = 0
    @State private var activityRefreshToken = 0
    @State private var selectedSectionId: String = N8nSetupSection.whereIsN8n.rawValue
    @State private var attentionSectionId: String?
    @State private var verifySucceeded = false
    /// Snapshot of the server binding used for the URL card, read on appear.
    @State private var serverPort = ServerConfiguration.default.port
    @State private var serverExposedToNetwork = false
    /// Master write toggle from Connection Center; push fails while this is off.
    @State private var globalWritesEnabled = true

    private let manager = AgentChannelConnectionManager.shared
    private let service = AgentChannelConnectionService.shared

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
                case .whereIsN8n:
                    whereSectionContent
                case .howN8nCalls:
                    callSectionContent
                case .whoMaySpeak:
                    whoSectionContent
                case .howOsaurusReplies:
                    replySectionContent
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

    private var inboundURL: String {
        N8nSetupRecipe.inboundURL(
            connectionId: displayId,
            port: serverPort,
            topology: draft.topology
        )
    }

    private var pollURLTemplate: String {
        N8nSetupRecipe.pollURL(
            connectionId: displayId,
            port: serverPort,
            topology: draft.topology
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

    // MARK: - Section state

    private func sectionCompleted(_ sectionId: String) -> Bool {
        switch N8nSetupSection(rawValue: sectionId) {
        case .whereIsN8n:
            return !trimmedDraftId.isEmpty
        case .howN8nCalls:
            return hasSecret
        case .whoMaySpeak:
            return !allowedConversations.isEmpty && !allowedSenders.isEmpty
        case .howOsaurusReplies:
            return draft.inboundDispatchEnabled && (draft.inboundTarget != nil || !draft.inboundRoutes.isEmpty)
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

    // MARK: - 1. Where is n8n?

    private var whereSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(
                "Pick where n8n runs so the inbound URL matches how it reaches this Mac.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            identitySection
            SettingsDivider()
            topologySection
            SettingsDivider()
            inboundURLSection
            if draft.topology.revealsPlaintextToggle {
                SettingsDivider()
                transportPolicySection
            }
            if draft.topology.revealsSecureChannel {
                SettingsDivider()
                secureChannelSection
            }
        }
    }

    private var topologySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(
                L("Where is n8n?"),
                detail: L("Only the matching inbound URL is shown below.")
            )

            Picker(selection: $draft.topology) {
                ForEach(N8nTopology.allCases, id: \.self) { topology in
                    Text(topology.title).tag(topology)
                }
            } label: {
                EmptyView()
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)

            Text(topologyHelp)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var topologyHelp: String {
        switch draft.topology {
        case .thisMac:
            return L("n8n on this Mac calls 127.0.0.1. No public URL is needed.")
        case .dockerDesktop:
            return L(
                "Docker Desktop on this Mac forwards host.docker.internal over loopback, so it counts as a same-Mac caller."
            )
        case .lan:
            return L(
                "A machine on your LAN must reach this Mac's address. Expose the server to the network, then choose whether plaintext HTTP is allowed."
            )
        case .remote:
            return L(
                "Remote n8n should wrap /agents/.../run through Secure Channel. The inbound webhook is still secret-verified and bearer-exempt — an osk-v1 key is not that secret."
            )
        }
    }

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(
                L("Name this channel"),
                detail: L(
                    "The connection id is part of the inbound URL and how agent_channel tools refer to this channel."
                )
            )

            HStack(alignment: .top, spacing: 12) {
                StyledSettingsTextField(
                    label: L("Connection ID (required)"),
                    text: $draft.id,
                    placeholder: "n8n-local",
                    help: L("Stable id used in the webhook URL. Lowercase letters, digits and dashes.")
                )
                .disabled(!draft.isNew)
                StyledSettingsTextField(
                    label: L("Display Name"),
                    text: $draft.name,
                    placeholder: "n8n",
                    help: L("Human-readable name shown in the channel list.")
                )
            }

            SettingsToggle(
                title: L("Enabled"),
                description: L(
                    "Disabled connections answer every inbound and poll request with 403 connection_disabled."
                ),
                isOn: $draft.enabled
            )
        }
    }

    private var secretSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(
                L("Shared secret"),
                detail: L(
                    "Generate a long random value, paste it here, and store the same value in an n8n credential. Every inbound and poll request must prove it with the header below."
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

            HStack(spacing: 8) {
                Button(action: generateSecret) {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 10))
                        Text("Generate", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
                .help(L("Fill the field with a random 48-character secret"))

                Text("Saved to the macOS Keychain when you press Save.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }

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
            }

            AgentChannelAdvancedSection {
                StyledSettingsTextField(
                    label: L("Header Name"),
                    text: $draft.verificationHeaderName,
                    placeholder: draft.verification.effectiveHeaderName,
                    help: L("Override the header n8n sends the secret or signature in. Leave empty for the default.")
                )
            }
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

    private var inboundURLSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(
                L("Point n8n at this URL"),
                detail: L(
                    "Use an HTTP Request node: POST the envelope to this inbound URL, then GET the poll_url from the 202 response until status is completed."
                )
            )

            AgentChannelCopyableCommand(
                command: "POST \(inboundURL)",
                caption: draft.topology.title,
                onCopied: { showStatus(L("Inbound URL copied"), isError: false) }
            )
            AgentChannelCopyableCommand(
                command: "GET \(pollURLTemplate)",
                caption: L("Poll for the reply (same header)"),
                onCopied: { showStatus(L("Poll URL copied"), isError: false) }
            )

            if draft.topology == .lan || draft.topology == .remote, !serverExposedToNetwork {
                Text(
                    "Expose the server to the network in Server settings before a LAN or remote host can reach this address.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var transportPolicySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(L("Remote callers"))

            SettingsToggle(
                title: L("Allow plaintext HTTP from non-loopback callers"),
                description: L(
                    "Off: callers that are not on this Mac must use Secure Channel (end-to-end encrypted) or they receive 426. On: the shared secret alone authenticates them — use only on trusted networks such as a LAN n8n host."
                ),
                isOn: $draft.plaintextAllowed
            )

            if draft.plaintextAllowed {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.warningColor)
                        .padding(.top, 1)
                    Text(
                        "Plaintext is allowed. Anyone who can reach this port and knows the secret can send events and read replies for this connection.",
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

    private var secureChannelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AgentChannelSectionHeading(
                L("Secure Channel access key"),
                detail: L(
                    "An osk-v1 key wraps /secure/call around /agents/.../run or dispatch. It is not the inbound webhook secret — inbound stays bearer-exempt and secret-verified."
                )
            )

            if shareableAgent != nil {
                Button {
                    showShareSheet = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "key.horizontal")
                            .font(.system(size: 10))
                        Text("Generate an access key for Secure Channel", bundle: .module)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(theme.accentColor)
                }
                .buttonStyle(PlainButtonStyle())
                .help(L("Issue an agent-scoped osk-v1 key so remote n8n can call Osaurus end-to-end encrypted."))
            } else {
                Text(
                    "Pick a local agent in How Osaurus replies to issue a Secure Channel access key from here.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 2. How n8n calls Osaurus

    private var callSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            secretSection
            SettingsDivider()
            recipeSection
        }
    }

    private var recipeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(
                L("HTTP Request recipe"),
                detail: L(
                    "Paste this into an n8n HTTP Request node. conversation_id and sender.id must match a line in Who may speak."
                )
            )

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

            Text(
                "Attachments in the envelope are metadata-only; Osaurus does not fetch the file bytes.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 3. Who may speak

    private var whoSectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                AgentChannelSectionHeading(
                    L("Authorize incoming events"),
                    detail: L(
                        "These are workflow-declared IDs (Teams thread, mailbox, widget tenant), not chat rooms. Fail-closed: conversation_id and sender.id in the HTTP Request body must both match a line here."
                    )
                )

                Text(
                    "Example: conversation_id: \"n8n-test\" must equal an allowlisted line.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)

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
    }

    // MARK: - 4. How Osaurus replies

    private var replySectionContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            dispatchSection
            SettingsDivider()
            outboundSection
        }
    }

    private var dispatchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Reply to incoming events"))

            SettingsToggle(
                title: L("Reply with an Agent"),
                description: L(
                    "Choose which agent answers verified, allowlisted n8n events. Replies run in a private channel session per conversation; external-surface tool restrictions still apply."
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

                Text(
                    "Default: n8n Wait + GET the poll_url from the 202. Optional push below posts to an n8n Webhook trigger.",
                    bundle: .module
                )
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
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
                    "Posts the agent's reply as a signed JSON envelope to an n8n Webhook trigger. Requires a public HTTPS URL — loopback, private ranges and plain HTTP are refused (C2). Use poll for local n8n."
                )
            )

            StyledSettingsTextField(
                label: L("Outbound Webhook URL"),
                text: $draft.outboundWebhookURL,
                placeholder: "https://n8n.example.com/webhook/osaurus-reply",
                help: L("Leave empty to keep replies poll-only.")
            )

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

    // MARK: - 5. Live check

    private var liveSectionContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            AgentChannelSectionHeading(L("Verify an incoming event"))

            Text(
                "Save first, then trigger the n8n workflow (or POST an envelope with curl) and watch each stage appear here.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)

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

            SettingsDivider()

            AgentChannelAdvancedSection {
                VStack(alignment: .leading, spacing: 8) {
                    AgentChannelCopyableCommand(
                        command: curlExample,
                        caption: L("Copy curl (matches topology and verify mode)"),
                        lineLimit: 4,
                        onCopied: { showStatus(L("Example copied"), isError: false) }
                    )
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
        if let connection {
            draft = N8nConnectionDraft(connection: connection)
            let pluginId = draft.keychainPluginId
            let secretName = draft.secretName
            Task.detached {
                let saved = ToolSecretsKeychain.hasSecret(id: secretName, for: pluginId, agentId: Agent.defaultId)
                await MainActor.run { secretSaved = saved }
            }
        }
        selectedSectionId = AgentChannelSetupFlow.initialSection(
            in: N8nSetupSection.sections,
            required: N8nSetupSection.requiredSectionIds,
            isComplete: { sectionCompleted($0) },
            fallback: N8nSetupSection.fallbackSectionId
        )
    }

    private func generateSecret() {
        var bytes = [UInt8](repeating: 0, count: 36)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        pendingSecret = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        showStatus(L("Secret generated — copy it into n8n before saving"), isError: false)
    }

    private func removeSecret() {
        pendingSecret = ""
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

    /// First cross-field problem the save would reject, or nil when the
    /// draft is persistable.
    private func validationFailure() -> (message: String, section: N8nSetupSection)? {
        if trimmedDraftId.isEmpty {
            return (L("Enter a connection id."), .whereIsN8n)
        }
        if !hasSecret {
            return (L("Paste or generate the channel secret before saving."), .howN8nCalls)
        }
        if draft.inboundDispatchEnabled, draft.inboundTarget == nil, draft.inboundRoutes.isEmpty {
            return (L("Choose an agent to reply with, or turn off Reply with an Agent."), .howOsaurusReplies)
        }
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
            withAnimation(.easeOut(duration: 0.15)) {
                selectedSectionId = failure.section.rawValue
            }
            showStatus(failure.message, isError: true)
            return
        }
        isSaving = true
        let connection = draft.connection()
        let secret = pendingSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let pluginId = N8nConnectionDraft.keychainPluginId(for: connection.id)
        let secretName = connection.n8n?.secretName ?? AgentChannelN8nConfiguration.defaultSecretName
        let originalId = draft.originalId
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
                    attentionSectionId = N8nSetupSection.howN8nCalls.rawValue
                    showStatus(L("Could not store the channel secret in the Keychain."), isError: true)
                    return
                }
                do {
                    try manager.upsertConnection(connection, replacingOriginalId: originalId)
                    if !secret.isEmpty {
                        secretSaved = true
                        pendingSecret = ""
                    }
                    draft.originalId = connection.id
                    draft.id = connection.id
                    attentionSectionId = nil
                    healthRefreshToken += 1
                    _ = ToastManager.shared.success(L("n8n channel saved"))
                    onDidChange()
                    showStatus(L("Saved. Trigger the workflow, then verify below."), isError: false)
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedSectionId = N8nSetupSection.liveCheck.rawValue
                    }
                } catch {
                    let section: N8nSetupSection
                    if case AgentChannelConnectionManagerError.invalidN8nOutboundURL = error {
                        section = .howOsaurusReplies
                    } else {
                        section = .whereIsN8n
                    }
                    attentionSectionId = section.rawValue
                    withAnimation(.easeOut(duration: 0.15)) {
                        selectedSectionId = section.rawValue
                    }
                    showStatus(error.localizedDescription, isError: true)
                }
            }
        }
    }

    private func performDelete() {
        do {
            try manager.deleteConnection(id: draft.id)
            _ = ToastManager.shared.success(L("Channel connection deleted"))
            onDidChange()
            dismiss()
        } catch {
            showStatus(error.localizedDescription, isError: true)
        }
    }

    private func diagnose() {
        withAnimation(.easeOut(duration: 0.15)) {
            selectedSectionId = N8nSetupSection.liveCheck.rawValue
        }
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
            L(
                "Waiting for an n8n event. Trigger the workflow now with the saved secret and an allowlisted conversation and sender."
            ),
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
                if let event = outcome.event {
                    presentVerifyOutcome(event, timedOutWaitingForMore: outcome.timedOutWaitingForMore)
                } else {
                    showStatus(
                        L("No n8n event arrived within 90 seconds."),
                        details: [
                            L("Confirm the workflow posts to the inbound URL shown in Where is n8n? with the saved secret."),
                            L("Confirm conversation_id and sender.id are both allowlisted in Who may speak."),
                            L(
                                "From another machine on the network, confirm plaintext is allowed or the call goes through Secure Channel."
                            ),
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

// MARK: - Draft

/// Editable projection of an n8n `AgentChannelConnection`. Kept view-agnostic
/// so the round trip (connection -> draft -> connection) is unit-testable.
struct N8nConnectionDraft: Equatable {
    var originalId: String?
    var id = ""
    var name = ""
    var enabled = true
    var verificationMethod: AgentChannelSourceVerificationMethod = .hmacSHA256
    var verificationHeaderName = ""
    var secretName = AgentChannelN8nConfiguration.defaultSecretName
    var plaintextAllowed = false
    var conversationAllowlistText = ""
    var senderAllowlistText = ""
    var allowBotMessages = false
    var inboundDispatchEnabled = false
    var inboundTarget: AgentDispatchTarget?
    var inboundRoutes: [AgentChannelDispatchRoute] = []
    var inboundAutoReplyEnabled = false
    var outboundWebhookURL = ""
    var outboundSignBodies = true
    /// UI-only: which inbound URL the sheet shows. Not persisted.
    var topology: N8nTopology = .thisMac

    init() {}

    init(connection: AgentChannelConnection) {
        originalId = connection.id
        id = connection.id
        name = connection.name
        enabled = connection.enabled
        conversationAllowlistText = connection.inboundAuthorization.roomAllowlist.joined(separator: "\n")
        senderAllowlistText = connection.inboundAuthorization.senderAllowlist.joined(separator: "\n")
        allowBotMessages = connection.inboundAuthorization.allowBotMessages
        let n8n = connection.n8n ?? AgentChannelN8nConfiguration()
        verificationMethod = n8n.inboundVerification.method
        verificationHeaderName = n8n.inboundVerification.headerName ?? ""
        secretName = n8n.secretName
        plaintextAllowed = n8n.remoteTransportPolicy == .plaintextAllowed
        topology = N8nTopology.inferred(plaintextAllowed: plaintextAllowed)
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
            remoteTransportPolicy: plaintextAllowed ? .plaintextAllowed : .secureChannelRequired,
            outbound: AgentChannelN8nOutboundConfiguration(
                webhookURL: outboundWebhookURL,
                signBodies: outboundSignBodies
            )
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
