//
//  Participant.swift
//  osaurus
//
//  Who is in a conversation or asked for something: the owner, the owner's
//  own devices, a workspace teammate, an invite-link peer, a colleague's
//  agent on another machine, a channel sender (Slack, Telegram, ...), or the
//  agent itself. One value type is used everywhere a "who" is shown or
//  recorded — attention items, notification text, per-turn authorship,
//  Insights rows, the workspace audit trail — so the same person reads the
//  same on every surface (docs/AGENT_ATTENTION.md, "Participant naming").
//
//  Naming contract: people are identified by their `@handle` with their
//  Osaurus ID (0x wallet) beside it; agents by agent name plus agent
//  address. A free-text display name is decoration (tooltips, detail
//  popovers) and is never the only identifier shown.
//

import Foundation

public enum ParticipantKind: String, Codable, Sendable, CaseIterable {
    /// The person who owns this Mac's identity, at this Mac.
    case owner
    /// The owner on another of their devices (paired phone, another Mac).
    case ownerDevice = "owner_device"
    /// A workspace member reaching a shared agent with a workspace-minted key.
    case teammate
    /// Someone who redeemed an invite link for a shared agent.
    case invitePeer = "invite_peer"
    /// A colleague's agent calling one of this Mac's agents.
    case remoteAgent = "remote_agent"
    /// A sender on a messaging channel (Slack, Discord, Telegram, ...).
    case channelSender = "channel_sender"
    /// The agent hosted here that is answering the conversation.
    case agent
    /// On a caller's Mac: the person who owns the shared agent they are
    /// talking to, speaking in that conversation.
    case agentOwner = "agent_owner"

    public var isHuman: Bool {
        switch self {
        case .owner, .ownerDevice, .teammate, .invitePeer, .channelSender, .agentOwner: return true
        case .remoteAgent, .agent: return false
        }
    }

    /// Whether content this participant writes is trusted like the owner's
    /// own input. Everything else is wrapped as untrusted before a model
    /// sees it.
    public var isTrusted: Bool {
        switch self {
        case .owner, .ownerDevice, .agent: return true
        case .teammate, .invitePeer, .remoteAgent, .channelSender, .agentOwner: return false
        }
    }
}

/// A snapshot of a participant. Stored on turns and log rows as written, so
/// history stays correct when a handle or display name changes later.
public struct Participant: Codable, Equatable, Hashable, Sendable {
    public var kind: ParticipantKind
    /// Claimed Osaurus ID handle without the `@` (`rex-42`), when known.
    public var handle: String?
    /// Lowercased 0x wallet (the person's Osaurus ID address), when known.
    public var wallet: String?
    /// Router display name or channel display name. Decoration only.
    public var displayName: String?
    /// For `agent` / `remoteAgent`: the agent's name.
    public var agentName: String?
    /// For `agent` / `remoteAgent`: the agent's lowercased address.
    public var agentAddress: String?
    /// For `remoteAgent`: the handle of the person who owns that agent.
    public var ownerHandle: String?
    /// For `channelSender`: the channel kind raw value (`slack`, ...).
    public var channel: String?
    /// For `channelSender`: the platform username, without `@`.
    public var channelUsername: String?
    /// For `channelSender`: the platform's sender id.
    public var channelSenderId: String?
    /// For `ownerDevice`: a short device label ("iPhone").
    public var deviceLabel: String?
    /// For `remoteAgent`: the name or owner handle is the caller's own
    /// unsigned claim. Shown as "unverified" wherever the name is.
    public var identityUnverified: Bool?

    public init(
        kind: ParticipantKind,
        handle: String? = nil,
        wallet: String? = nil,
        displayName: String? = nil,
        agentName: String? = nil,
        agentAddress: String? = nil,
        ownerHandle: String? = nil,
        channel: String? = nil,
        channelUsername: String? = nil,
        channelSenderId: String? = nil,
        deviceLabel: String? = nil
    ) {
        self.kind = kind
        self.handle = Self.normalizedHandle(handle)
        self.wallet = Self.nonEmpty(wallet)?.lowercased()
        self.displayName = Self.nonEmpty(displayName)
        self.agentName = Self.nonEmpty(agentName)
        self.agentAddress = Self.nonEmpty(agentAddress)?.lowercased()
        self.ownerHandle = Self.normalizedHandle(ownerHandle)
        self.channel = Self.nonEmpty(channel)
        self.channelUsername = Self.normalizedHandle(channelUsername)
        self.channelSenderId = Self.nonEmpty(channelSenderId)
        self.deviceLabel = Self.nonEmpty(deviceLabel)
    }

    /// Stable identity for grouping, filtering and leases. Wallet for
    /// people, agent address for agents, `channel:<kind>:<sender>` for
    /// channel senders, `owner` for the owner without a known wallet.
    public var key: String {
        switch kind {
        case .agent, .remoteAgent:
            if let agentAddress { return agentAddress }
        case .channelSender:
            return "channel:\(channel ?? "unknown"):\(channelSenderId ?? channelUsername ?? "unknown")"
        default:
            break
        }
        if let wallet { return wallet }
        if let handle { return "@" + handle }
        return kind == .owner || kind == .ownerDevice ? "owner" : kind.rawValue
    }

    /// `@rex-42`, or nil without a handle.
    public var atHandle: String? { handle.map { "@" + $0 } }

    static func normalizedHandle(_ value: String?) -> String? {
        guard var trimmed = nonEmpty(value) else { return nil }
        while trimmed.hasPrefix("@") { trimmed.removeFirst() }
        return trimmed.isEmpty ? nil : trimmed
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

/// The per-turn / per-row snapshot. Same shape as `Participant`; the alias
/// marks fields that are a point-in-time copy rather than a live lookup.
public typealias ParticipantRef = Participant

// MARK: - Builders

extension Participant {
    /// The owner at this Mac. `handle` / `wallet` default to the claimed
    /// Osaurus ID and the last signed router wallet.
    @MainActor
    static func owner(handle: String? = nil, wallet: String? = nil) -> Participant {
        Participant(
            kind: .owner,
            handle: handle ?? OsaurusIDService.shared.claimedHandle,
            wallet: wallet ?? OsaurusRouterWalletCache.lastSignedAddress
        )
    }

    /// The owner on another of their devices.
    @MainActor
    static func ownerDevice(_ label: String?) -> Participant {
        Participant(
            kind: .ownerDevice,
            handle: OsaurusIDService.shared.claimedHandle,
            wallet: OsaurusRouterWalletCache.lastSignedAddress,
            deviceLabel: label
        )
    }

    func markingUnverified(_ unverified: Bool) -> Participant {
        var copy = self
        copy.identityUnverified = unverified ? true : nil
        return copy
    }

    /// The agent hosted here.
    static func agent(name: String?, address: String?) -> Participant {
        Participant(kind: .agent, agentName: name, agentAddress: address)
    }

    /// A channel sender, from the adapter's metadata.
    static func channelSender(kind: ChannelKind, sender: ChannelSenderMetadata) -> Participant {
        Participant(
            kind: .channelSender,
            displayName: sender.displayName,
            channel: kind.rawValue,
            channelUsername: sender.username,
            channelSenderId: sender.senderId
        )
    }

    /// The caller of a hosted shared-agent run, from the session context the
    /// HTTP handler stamped. Paired-phone runs are the owner's device.
    static func caller(from context: WorkspaceSessionContext) -> Participant {
        if let kind = context.callerKind {
            return Participant(
                kind: kind,
                handle: context.callerHandle,
                wallet: context.callerVerifiedWallet,
                displayName: context.callerName,
                agentName: context.callerAgentName,
                agentAddress: context.callerAgentAddress,
                ownerHandle: context.callerAgentOwnerHandle
            ).markingUnverified(context.callerAgentIdentityUnverified == true)
        }
        return Participant(
            kind: context.isDirectShare ? .invitePeer : .teammate,
            handle: context.callerHandle,
            wallet: context.callerVerifiedWallet,
            displayName: context.callerName
        )
    }
}

// MARK: - Formatter

/// The single place that turns a participant into text. Every surface —
/// notifications, approval cards, transcript author chips, the sidebar,
/// Insights, the phone feed, SSE payloads — goes through it.
public enum ParticipantFormatter {
    /// `0x1234…abcd` (the existing short-address rule).
    public static func shortAddress(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))…\(address.suffix(4))"
    }

    static func channelLabel(_ raw: String?) -> String {
        guard let raw, let kind = ChannelKind(rawValue: raw) else { return raw?.capitalized ?? "Channel" }
        switch kind {
        case .discord: return "Discord"
        case .slack: return "Slack"
        case .telegram: return "Telegram"
        case .imessage: return "iMessage"
        case .whatsapp: return "WhatsApp"
        case .email: return "Email"
        case .n8n: return "n8n"
        case .jsonAgent: return "Webhook"
        }
    }

    /// The inline label.
    ///
    /// - `@alice · 0x9C3e…11aa` (person with a handle)
    /// - `0x9C3e…11aa` (person without one)
    /// - `You (@tpae)` (owner, when `viewerIsOwner`)
    /// - `Research Agent · 0xAB12…F291` (agent)
    /// - `Scout · 0x77d0…19be · @bob's agent` (someone else's agent)
    /// - `@username via Slack` (channel sender)
    public static func short(_ p: Participant, viewerIsOwner: Bool = true) -> String {
        switch p.kind {
        case .owner where viewerIsOwner:
            return p.atHandle.map { L("You (\($0))") } ?? L("You")
        case .ownerDevice where viewerIsOwner:
            let you = p.atHandle.map { L("You (\($0))") } ?? L("You")
            return p.deviceLabel.map { "\(you) · \($0)" } ?? you
        case .agent, .remoteAgent:
            return agentLabel(p)
        case .channelSender:
            let platform = channelLabel(p.channel)
            if let user = p.channelUsername { return L("@\(user) via \(platform)") }
            if let name = p.displayName { return L("\(name) via \(platform)") }
            return L("\(p.channelSenderId ?? L("Unknown sender")) via \(platform)")
        default:
            return personLabel(p)
        }
    }

    /// `@alice · 0x9C3e…11aa` / `0x9C3e…11aa`; display name only as the last
    /// resort when neither identifier is known (legacy rows).
    static func personLabel(_ p: Participant) -> String {
        var parts: [String] = []
        if let handle = p.atHandle { parts.append(handle) }
        if let wallet = p.wallet { parts.append(shortAddress(wallet)) }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        return p.displayName ?? L("Unknown")
    }

    static func agentLabel(_ p: Participant) -> String {
        var parts = [p.agentName ?? L("Agent")]
        if let address = p.agentAddress { parts.append(shortAddress(address)) }
        if p.kind == .remoteAgent, let owner = p.ownerHandle { parts.append(L("@\(owner)'s agent")) }
        if p.kind == .remoteAgent, p.identityUnverified == true { parts.append(L("unverified")) }
        return parts.joined(separator: " · ")
    }

    /// The handle-first label without the address (`@alice`, `Research
    /// Agent`), for tight spaces like a sidebar title. Falls back to the
    /// short address so it never shows only a free-text name for a person.
    public static func compact(_ p: Participant, viewerIsOwner: Bool = true) -> String {
        switch p.kind {
        case .owner where viewerIsOwner, .ownerDevice where viewerIsOwner:
            return p.atHandle.map { L("You (\($0))") } ?? L("You")
        case .agent, .remoteAgent:
            return p.agentName ?? p.agentAddress.map(shortAddress) ?? L("Agent")
        case .channelSender:
            return short(p)
        default:
            if let handle = p.atHandle { return handle }
            if let wallet = p.wallet { return shortAddress(wallet) }
            return p.displayName ?? L("Unknown")
        }
    }

    /// Every known field, full addresses, one per line — detail popovers and
    /// the Insights Who pane's copy text.
    public static func full(_ p: Participant) -> [(label: String, value: String)] {
        var rows: [(String, String)] = []
        switch p.kind {
        case .agent, .remoteAgent:
            if let name = p.agentName { rows.append((L("Agent"), name)) }
            if let address = p.agentAddress { rows.append((L("Agent address"), address)) }
            if let owner = p.ownerHandle { rows.append((L("Owner"), "@" + owner)) }
            if p.identityUnverified == true {
                rows.append((L("Identity"), L("Name and owner are unverified (older caller)")))
            }
        case .channelSender:
            rows.append((L("Channel"), channelLabel(p.channel)))
            if let user = p.channelUsername { rows.append((L("Username"), "@" + user)) }
            if let id = p.channelSenderId { rows.append((L("Sender ID"), id)) }
        default:
            if let handle = p.atHandle { rows.append((L("Handle"), handle)) }
            if let wallet = p.wallet { rows.append((L("Osaurus ID"), wallet)) }
            if let device = p.deviceLabel { rows.append((L("Device"), device)) }
        }
        if let name = p.displayName { rows.append((L("Name"), name)) }
        rows.append((L("Role"), roleLabel(p.kind)))
        return rows
    }

    public static func roleLabel(_ kind: ParticipantKind) -> String {
        switch kind {
        case .owner: return L("Owner")
        case .ownerDevice: return L("Owner (another device)")
        case .teammate: return L("Workspace teammate")
        case .invitePeer: return L("Guest")
        case .remoteAgent: return L("Remote agent")
        case .channelSender: return L("Channel sender")
        case .agent: return L("Agent")
        case .agentOwner: return L("Agent's owner")
        }
    }

    /// A short label for a bare `Participant.key` (filter chips): the
    /// short address for wallets and agent addresses, else the key itself.
    static func keyLabel(_ key: String) -> String {
        if key == "owner" { return L("You") }
        if key.hasPrefix("0x") { return shortAddress(key) }
        if key.hasPrefix("channel:") {
            let parts = key.split(separator: ":", maxSplits: 2).map(String.init)
            if parts.count == 3 { return L("\(parts[2]) via \(channelLabel(parts[1]))") }
        }
        return key
    }

    /// Spoken form for VoiceOver: no middle-dot separators, role included.
    public static func accessibilityLabel(_ p: Participant) -> String {
        "\(short(p).replacingOccurrences(of: " · ", with: ", ")), \(roleLabel(p.kind))"
    }

    /// The speaker label a model sees in a multi-party transcript.
    /// Addresses are kept short; handles and agent names identify.
    static func speakerLabel(_ p: Participant) -> String {
        switch p.kind {
        case .owner, .ownerDevice:
            return p.atHandle.map { "\($0) (owner)" } ?? "Owner"
        case .agent, .remoteAgent:
            return agentLabel(p)
        default:
            return short(p, viewerIsOwner: false)
        }
    }
}
