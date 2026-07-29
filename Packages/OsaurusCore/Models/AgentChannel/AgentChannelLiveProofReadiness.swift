//
//  AgentChannelLiveProofReadiness.swift
//  osaurus
//
//  Release-proof readiness classification for native Agent Channels.
//

import Foundation

enum AgentChannelLiveProofStatus: String, Equatable, Sendable {
    case ready
    case blocked
}

struct AgentChannelLiveProofReadinessReport: Equatable, Sendable {
    let kind: AgentChannelKind
    let status: AgentChannelLiveProofStatus
    let blockers: [String]
    let manualProof: [String]
    let notes: [String]

    var isReadyForLiveProof: Bool {
        status == .ready
    }
}

enum AgentChannelFeedbackSource: Equatable, Sendable {
    case nativeAgentChannel(AgentChannelKind)
    case legacyTelegramPlugin
    case unknown
}

struct AgentChannelFeedbackRouting: Equatable, Sendable {
    let source: AgentChannelFeedbackSource
    let appliesToNativeChannels: Bool
    let guidance: String
}

enum AgentChannelLiveProofReadiness {
    static func telegram(_ diagnostics: TelegramConnectionDiagnostics) -> AgentChannelLiveProofReadinessReport {
        var blockers: [String] = []
        var manualProof: [String] = []
        var notes: [String] = diagnostics.notes
        let readableChatIds = nonEmptyEntries(diagnostics.readableChatIds)
        let writableChatIds = nonEmptyEntries(diagnostics.writableChatIds)
        let senderAllowlist = nonEmptyEntries(diagnostics.senderAllowlist)

        if !diagnostics.tokenSaved {
            blockers.append("Save a Telegram bot token.")
        }
        if diagnostics.bot == nil {
            blockers.append("Run Test Connection until Telegram accepts the bot token.")
        }
        if !diagnostics.receiveStorageEnabled {
            blockers.append("Enable Store Incoming Messages for receive proof.")
        }
        if !diagnostics.longPollingEnabled {
            blockers.append("Enable Long Polling for local desktop receive proof.")
        }
        if diagnostics.webhook?.registered == true {
            blockers.append("Remove the registered Telegram webhook before long polling.")
        }
        if diagnostics.bot != nil && diagnostics.longPollingEnabled && diagnostics.webhook == nil {
            blockers.append("Verify no Telegram webhook is registered before long polling proof.")
        }
        if let probeError = diagnostics.webhook?.probeError {
            blockers.append("Verify Telegram webhook state before long polling proof: \(probeError)")
        }
        if readableChatIds.isEmpty {
            blockers.append("Add at least one readable Telegram chat id.")
        }
        if senderAllowlist.isEmpty {
            blockers.append("Add at least one authorized Telegram sender id.")
        }
        if diagnostics.writeEnabled && writableChatIds.isEmpty {
            blockers.append("Add at least one writable Telegram chat id or turn writes off.")
        }
        appendDiagnosticFailures(diagnostics.failures, to: &blockers)

        if diagnostics.writeEnabled {
            manualProof.append("Send one confirmed message to a write-allowlisted Telegram chat.")
        } else {
            notes.append("Telegram writes are off; live proof can cover receive/read-only behavior.")
        }
        manualProof.append("Send one inbound Telegram message from an authorized sender.")
        manualProof.append("Confirm an unauthorized sender in the same group is ignored.")
        manualProof.append("Restart Osaurus and confirm the Telegram inbox and configuration persist.")

        return AgentChannelLiveProofReadinessReport(
            kind: .telegram,
            status: blockers.isEmpty ? .ready : .blocked,
            blockers: blockers,
            manualProof: manualProof,
            notes: notes
        )
    }

    static func slack(_ diagnostics: SlackConnectionDiagnostics) -> AgentChannelLiveProofReadinessReport {
        var blockers: [String] = []
        var manualProof: [String] = []
        var notes: [String] = []
        let readableChannelIds = nonEmptyEntries(diagnostics.readableChannelIds)
        let writableChannelIds = nonEmptyEntries(diagnostics.writableChannelIds)
        let senderAllowlist = nonEmptyEntries(diagnostics.senderAllowlist)

        if !diagnostics.botTokenSaved {
            blockers.append("Save a Slack bot token.")
        }
        if !diagnostics.signingSecretSaved {
            notes.append("Signed Slack HTTP event proof is unavailable until a signing secret is saved.")
        }
        if !diagnostics.appTokenSaved {
            blockers.append("Save a Slack Socket Mode app token for local desktop receive proof.")
        }
        if diagnostics.identity == nil {
            blockers.append("Run Test Connection until Slack accepts the bot token.")
        }
        if diagnostics.configuredTeams.isEmpty {
            blockers.append("Add the Slack workspace/team id to the configured team allowlist.")
        } else {
            let rejectedTeams = diagnostics.configuredTeams.filter { $0.status != "accessible" }
            for team in rejectedTeams {
                blockers.append("Allowlisted Slack team \(team.id) is not usable: \(team.reason ?? team.status).")
            }
        }
        if readableChannelIds.isEmpty {
            blockers.append("Add at least one readable Slack channel id.")
        }
        if senderAllowlist.isEmpty {
            blockers.append("Add at least one authorized Slack sender id.")
        }
        if diagnostics.writeEnabled && writableChannelIds.isEmpty {
            blockers.append("Add at least one writable Slack channel id or turn writes off.")
        }
        if diagnostics.allowBroadcastMentions {
            notes.append("Broadcast mentions are enabled; release proof should confirm this is intentional.")
        }
        appendDiagnosticFailures(diagnostics.failures, to: &blockers)
        notes.append(contentsOf: diagnostics.warnings)

        if diagnostics.writeEnabled {
            manualProof.append("Send one confirmed message to a write-allowlisted Slack channel.")
        } else {
            notes.append("Slack writes are off; live proof can cover receive/read-only behavior.")
        }
        manualProof.append("Receive one Slack message through Socket Mode from an authorized sender.")
        manualProof.append("Confirm an unauthorized sender in the same channel is ignored.")
        manualProof.append("Restart Osaurus and confirm Slack transport health and configuration persist.")

        return AgentChannelLiveProofReadinessReport(
            kind: .slack,
            status: blockers.isEmpty ? .ready : .blocked,
            blockers: blockers,
            manualProof: manualProof,
            notes: notes
        )
    }

    static func discord(_ diagnostics: DiscordConnectionDiagnostics) -> AgentChannelLiveProofReadinessReport {
        var blockers: [String] = []
        var manualProof: [String] = []
        var notes: [String] = []
        let readableChannelIds = nonEmptyEntries(diagnostics.readableChannelIds)
        let writableChannelIds = nonEmptyEntries(diagnostics.writableChannelIds)
        let senderAllowlist = nonEmptyEntries(diagnostics.senderAllowlist)

        if !diagnostics.tokenSaved {
            blockers.append("Save a Discord bot token.")
        }
        if diagnostics.bot == nil {
            blockers.append("Run Test Connection until Discord accepts the bot token.")
        }
        if readableChannelIds.isEmpty {
            blockers.append("Mark at least one Discord channel as readable.")
        }
        if senderAllowlist.isEmpty {
            blockers.append("Add at least one authorized Discord sender.")
        }
        if diagnostics.writeEnabled && writableChannelIds.isEmpty {
            blockers.append("Mark at least one Discord channel as writable or turn writes off.")
        }
        appendDiagnosticFailures(diagnostics.failures, to: &blockers)
        notes.append(contentsOf: diagnostics.warnings)

        if diagnostics.writeEnabled {
            manualProof.append("Send one confirmed message to a write-allowlisted Discord channel.")
        } else {
            notes.append("Discord writes are off; live proof can cover receive/read-only behavior.")
        }
        manualProof.append("Receive one Discord message through polling from an authorized sender.")
        manualProof.append("Confirm an unauthorized sender in the same channel is ignored.")
        manualProof.append("Restart Osaurus and confirm Discord transport health and configuration persist.")

        return AgentChannelLiveProofReadinessReport(
            kind: .discord,
            status: blockers.isEmpty ? .ready : .blocked,
            blockers: blockers,
            manualProof: manualProof,
            notes: notes
        )
    }

    static func imessage(_ diagnostics: IMessageConnectionDiagnostics) -> AgentChannelLiveProofReadinessReport {
        var blockers: [String] = []
        var manualProof: [String] = []
        var notes: [String] = diagnostics.notes
        let readableChatIds = nonEmptyEntries(diagnostics.readableChatIds)
        let writableChatIds = nonEmptyEntries(diagnostics.writableChatIds)
        let senderAllowlist = nonEmptyEntries(diagnostics.senderAllowlist)

        if !diagnostics.helperVerified {
            blockers.append(
                "Install and verify the imsg helper — bundled or downloaded from iMessage settings (state: \(diagnostics.helperState))."
            )
        }
        if !diagnostics.fullDiskAccess {
            blockers.append("Grant Full Disk Access so Osaurus can read the Messages database.")
        }
        // imsg exposes no sign-in probe; only a future helper release could
        // report a definite signed-out state.
        if diagnostics.messagesSignedIn == false {
            blockers.append("Sign in to Messages.app with an iMessage account on this Mac.")
        } else if diagnostics.messagesSignedIn == nil {
            manualProof.append(
                "Confirm Messages.app is signed in with an Apple Account on this Mac (Osaurus cannot probe this)."
            )
        }
        if !diagnostics.receiveStorageEnabled {
            blockers.append("Enable Store Incoming Messages for receive proof.")
        }
        if !diagnostics.receivePollingEnabled {
            blockers.append("Enable iMessage receive polling for local desktop receive proof.")
        }
        if readableChatIds.isEmpty {
            blockers.append("Add at least one readable iMessage chat.")
        }
        if senderAllowlist.isEmpty {
            blockers.append("Add at least one authorized iMessage sender.")
        }
        if diagnostics.writeEnabled {
            if writableChatIds.isEmpty {
                blockers.append("Add at least one writable iMessage chat or turn writes off.")
            }
            if !diagnostics.automationMessages {
                blockers.append("Grant Messages Automation so Osaurus can send through Messages.app.")
            }
        }
        appendDiagnosticFailures(diagnostics.failures, to: &blockers)

        if diagnostics.writeEnabled {
            manualProof.append("Send one confirmed message to a write-allowlisted iMessage chat.")
        } else {
            notes.append("iMessage writes are off; live proof can cover receive/read-only behavior.")
        }
        manualProof.append("Receive one inbound iMessage from an authorized sender.")
        manualProof.append("Confirm an unauthorized sender in the same chat is ignored.")
        manualProof.append("Restart Osaurus and confirm the iMessage cursor, inbox, and configuration persist.")
        if diagnostics.advancedActionsEnabled {
            if diagnostics.bridgeAvailable {
                manualProof.append(
                    "Exercise each enabled advanced action (edit, unsend, tapback, typing, attachments) against a write-allowlisted chat."
                )
                manualProof.append(
                    "Restart Messages.app and confirm the bridge re-injects before calling advanced actions again."
                )
            } else {
                notes.append(
                    "Advanced actions are enabled but the private-API bridge is not active; advanced live proof is blocked until the operator disables SIP and Library Validation on a dedicated Mac."
                )
            }
        }

        return AgentChannelLiveProofReadinessReport(
            kind: .imessage,
            status: blockers.isEmpty ? .ready : .blocked,
            blockers: blockers,
            manualProof: manualProof,
            notes: notes
        )
    }

    static func routeFeedback(source: AgentChannelFeedbackSource) -> AgentChannelFeedbackRouting {
        switch source {
        case .nativeAgentChannel(let kind):
            return AgentChannelFeedbackRouting(
                source: source,
                appliesToNativeChannels: true,
                guidance: "Investigate the native \(providerName(kind)) Agent Channel path."
            )
        case .legacyTelegramPlugin:
            return AgentChannelFeedbackRouting(
                source: source,
                appliesToNativeChannels: false,
                guidance: "Investigate the legacy Telegram plugin separately. Do not claim the native Telegram Agent Channel fixed this path until the plugin is tested or a migration is complete."
            )
        case .unknown:
            return AgentChannelFeedbackRouting(
                source: source,
                appliesToNativeChannels: false,
                guidance: "Clarify whether the report came from native Agent Channels or a legacy plugin before assigning it to the channel implementation."
            )
        }
    }

    private static func providerName(_ kind: AgentChannelKind) -> String {
        switch kind {
        case .discord:
            return "Discord"
        case .slack:
            return "Slack"
        case .telegram:
            return "Telegram"
        case .imessage:
            return "iMessage"
        case .customHTTP:
            return "Custom HTTP"
        }
    }

    private static func nonEmptyEntries(_ values: [String]) -> [String] {
        values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func appendDiagnosticFailures(_ failures: [String], to blockers: inout [String]) {
        for failure in failures where !failure.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blockers.append(failure)
        }
    }
}
