//
//  SharedAgentIdentity.swift
//  osaurus
//
//  One answer to "who is this shared agent?" for every surface that names a
//  workspace/shared agent: the chat sidebar, the composer lock notice, the
//  empty-state hero, the tab chip, the Workspaces roster, the unshare alert,
//  and the Agents tab's remote cards. Before this each surface resolved the
//  name/avatar/model from a different store in a different order, so the
//  same agent could be "Dinoki" in one place and "Editorial Writer" in
//  another.
//
//  Naming contract (decided with the product owner):
//  - The user's OWN shared agent is named by its local `Agent.name` — that
//    is what they see everywhere else in the app.
//  - A TEAMMATE's shared agent is named by the router display name the
//    sharer typed in the Share sheet (the roster's `display_name`). The
//    host's live agent name is a fallback for rosters without one; the
//    short address is the last resort.
//

import Foundation

/// Resolved identity for a shared agent address. Value type, cheap to
/// build; resolve on demand from the observed stores rather than caching.
struct SharedAgentIdentity: Equatable {
    /// Lowercased agent address.
    let address: String
    /// Display name per the naming contract above.
    let name: String
    /// Mascot id for `AgentAvatarView`, when known (local agent's avatar,
    /// or the live avatar captured from the remote host). nil = monogram.
    let avatar: String?
    /// Custom avatar image, only for the user's own local agents.
    let customAvatarURL: URL?
    /// Full model id the agent runs on, when known.
    let model: String?
    /// The teammate who shared the agent; nil for the user's own agents.
    let ownerName: String?
    /// The workspace the agent is shared through (first match), if any.
    let workspaceId: String?
    let workspaceName: String?
    /// Description shown under the agent's name (roster description first,
    /// then the pairing's, then the local agent's).
    let description: String?
    /// True when the agent is one of THIS Mac's agents (shared by the user).
    let isMine: Bool
    /// The local agent record for own agents; nil for teammates' agents or
    /// an own agent that has since been deleted locally.
    let localAgent: Agent?
    /// The teammate pairing record, when paired on this Mac.
    let paired: RemoteAgent?
    /// The roster row, when the agent is currently on a loaded roster.
    let rosterAgent: OsaurusRouterWorkspaceAgent?

    /// Short model label for badges (`RemoteAgent.shortModelLabel`).
    var modelLabel: String? {
        guard let model, !model.isEmpty else { return nil }
        return RemoteAgent.shortModelLabel(model)
    }

    /// `0xABCD…F291`.
    var shortAddress: String { Self.shortAddress(address) }

    /// The router display name the sharer typed, when it differs from the
    /// resolved name (only possible for own agents, whose title is the local
    /// name). Surfaces "shared as “X”" so a mistaken share name is visible.
    var sharedAsName: String? {
        guard isMine,
            let shared = rosterAgent?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !shared.isEmpty, shared != name
        else { return nil }
        return shared
    }

    /// An own agent the roster still lists but whose local record is gone
    /// (deleted on this Mac). It can only be unshared.
    var isMissingLocally: Bool { isMine && localAgent == nil }

    static func shortAddress(_ raw: String) -> String {
        guard raw.count > 12 else { return raw }
        return "\(raw.prefix(6))…\(raw.suffix(4))"
    }

    // MARK: - Pure resolution

    /// Resolve from explicit inputs. Pure so it is unit-testable; the
    /// `resolve(address:)` convenience gathers the inputs from the live stores.
    static func make(
        address rawAddress: String,
        rosterAgent: OsaurusRouterWorkspaceAgent?,
        workspace: OsaurusRouterWorkspaceSummary?,
        paired: RemoteAgent?,
        localAgent: Agent?,
        localEffectiveModel: String?,
        liveEffectiveModel: String?,
        lastKnownName: String?,
        isMine: Bool
    ) -> SharedAgentIdentity {
        let address = rawAddress.lowercased()
        let rosterName = rosterAgent?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairedName = paired?.name.trimmingCharacters(in: .whitespacesAndNewlines)

        let name: String
        if isMine, let local = localAgent {
            name = local.displayName
        } else if let rosterName, !rosterName.isEmpty {
            name = rosterName
        } else if let pairedName, !pairedName.isEmpty {
            name = pairedName
        } else if let lastKnownName, !lastKnownName.isEmpty {
            name = lastKnownName
        } else {
            name = shortAddress(rawAddress)
        }

        let model: String?
        if isMine {
            model = localEffectiveModel ?? localAgent?.defaultModel
        } else if let live = liveEffectiveModel, !live.isEmpty {
            model = live
        } else {
            model = paired?.model
        }

        let description = [
            rosterAgent?.description,
            paired?.description,
            localAgent?.description,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }

        let ownerName: String? = isMine ? nil : rosterAgent?.owner?.friendlyName

        return SharedAgentIdentity(
            address: address,
            name: name,
            avatar: isMine ? localAgent?.avatar : paired?.avatar,
            customAvatarURL: isMine ? localAgent?.customAvatarURL : nil,
            model: model,
            ownerName: ownerName,
            workspaceId: workspace?.id ?? paired?.workspaceId,
            workspaceName: workspace?.name,
            description: description,
            isMine: isMine,
            localAgent: isMine ? localAgent : nil,
            paired: paired,
            rosterAgent: rosterAgent
        )
    }

    // MARK: - Live resolution

    /// Resolve from the live stores. `liveEffectiveModel` is the window's
    /// pinned effective model for the currently connected remote agent, when
    /// the caller has one (it beats the pairing's last-known model).
    @MainActor
    static func resolve(address: String, workspaceId: String? = nil, liveEffectiveModel: String? = nil) -> SharedAgentIdentity {
        let roster = WorkspaceRosterStore.shared
        let rosterAgent =
            workspaceId.map { roster.agent(forAddress: address, workspaceId: $0) } ?? roster.agent(forAddress: address)
        let paired = RemoteAgentManager.shared.remoteAgent(forAddress: address,
            workspaceId: workspaceId?.isEmpty == false ? workspaceId : nil
        )
        let localAgent = AgentManager.shared.agent(byAddress: address)
        let isMine =
            localAgent != nil
            || (rosterAgent.map { WorkspacesService.shared.isSelf($0.owner) } ?? false)
        var workspace = workspaceId.flatMap { id in roster.rosters.first { $0.id == id }?.workspace }
        if workspace == nil, let id = paired?.workspaceId {
            workspace = roster.rosters.first { $0.id == id }?.workspace
        }
        return make(
            address: address,
            rosterAgent: rosterAgent,
            workspace: workspace,
            paired: paired,
            localAgent: localAgent,
            localEffectiveModel: localAgent.flatMap { AgentManager.shared.effectiveModel(for: $0.id) },
            liveEffectiveModel: liveEffectiveModel,
            lastKnownName: roster.lastKnownName(forAddress: address),
            isMine: isMine
        )
    }
}

// MARK: - Connection status

/// Where a shared-agent conversation stands, as one vocabulary for every
/// surface: the composer lock notice, the empty-state badge, the sidebar
/// row, and the Workspaces roster row. Each case owns exactly one icon,
/// tint role, and action label (see `SharedAgentStatusPresentation`).
enum SharedAgentStatus: Equatable {
    /// Paired, connected, and the secure channel is up — the user can send.
    case ready
    /// Access or availability has not been verified recently.
    case checking
    /// Pairing or the connect + model-pin handshake is in flight.
    case connecting
    /// The teammate's Osaurus that hosts the agent isn't reachable.
    case offline(lastSeen: Date?)
    /// Not paired / connect failed. `hasAttempted` distinguishes "never
    /// tried" (action: Connect) from "tried and failed" (action: Retry).
    case notConnected(reason: String?, hasAttempted: Bool)
    /// Gone for good from this Mac's point of view: unshared, membership
    /// lost, or Router turned off. `fix` says where the user can act.
    case unavailable(reason: String, fix: Fix)
    /// A teammate's conversation served by this host — read-only here.
    case readOnlyTeammate(callerName: String?)

    enum Fix: Equatable {
        /// Open Settings ▸ Workspaces (unshared / not a member).
        case openWorkspaces
        /// Open the Osaurus Router toggle (Router is off).
        case enableRouter
        /// Nothing the user can do here.
        case none
    }

    /// Whether the user can send in this state.
    var canSend: Bool { self == .ready }

    /// Precedence: teammate-served → unavailable (roster loaded and no
    /// longer lists the agent, or Router off) → offline (router/relay
    /// presence, incl. the force-offline override) → pairing/handshake in
    /// flight → not connected (unpaired, unbound, or failed) → ready.
    /// Unverified workspace availability pauses sending in the checking state.
    ///
    /// `workspaceId` empty means the tab was stamped before any roster
    /// loaded; it never reads as unavailable. `.unknown` presence is not
    /// offline. A stale connect failure is dropped when the roster says
    /// offline (the store clears it too; this is belt and braces).
    static func derive(
        isServedForTeammate: Bool,
        callerLabel: String?,
        workspaceId: String,
        rosterLists: Bool,
        rosterHasLoaded: Bool,
        routerEnabled: Bool,
        workspaceName: String?,
        presence: WorkspaceRosterStore.Presence,
        isPaired: Bool,
        isBoundToProvider: Bool,
        isPairing: Bool,
        connectFailure: String?,
        hasAttempted: Bool,
        phase: RemoteAgentConnectionPhase
    ) -> SharedAgentStatus {
        if isServedForTeammate {
            return .readOnlyTeammate(callerName: callerLabel)
        }
        if !rosterLists, rosterHasLoaded, !workspaceId.isEmpty {
            if !routerEnabled {
                return .unavailable(
                    reason: L("Osaurus Router is turned off, so workspace agents can't be reached."),
                    fix: .enableRouter
                )
            }
            if let workspaceName {
                return .unavailable(
                    reason: String(format: L("it's no longer shared with %@."), workspaceName),
                    fix: .openWorkspaces
                )
            }
            return .unavailable(
                reason: L("you're no longer a member of the workspace that shared it."),
                fix: .openWorkspaces
            )
        }
        if !workspaceId.isEmpty, !routerEnabled {
            return .unavailable(reason: L("Osaurus Router is turned off."), fix: .enableRouter)
        }
        if !workspaceId.isEmpty, presence == .unknown { return .checking }
        if case .offline(let lastSeen) = presence {
            return .offline(lastSeen: lastSeen)
        }
        if isPairing { return .connecting }
        if let connectFailure { return .notConnected(reason: connectFailure, hasAttempted: true) }
        if !isPaired || !isBoundToProvider {
            if isPairing { return .connecting }
            return .notConnected(reason: connectFailure, hasAttempted: hasAttempted || connectFailure != nil)
        }
        switch phase {
        case .connecting, .idle:
            return .connecting
        case .failed(let reason):
            return .notConnected(reason: reason, hasAttempted: true)
        case .connected:
            return .ready
        }
    }

    /// Status for the user's OWN shared agent as teammates experience it:
    /// reachable only while its relay tunnel is up. Pure so list rows and
    /// tests share one mapping.
    static func forOwnAgent(relayStatus: AgentRelayStatus?) -> SharedAgentStatus {
        switch relayStatus {
        case .connected: return .ready
        case .connecting: return .connecting
        case .error(let message):
            return .notConnected(reason: message, hasAttempted: true)
        case .disconnected, nil:
            return .notConnected(
                reason: L("relay is off — teammates can't reach it."),
                hasAttempted: false
            )
        }
    }

    /// Status for a teammate's roster agent as a list row shows it (sidebar,
    /// Workspaces panel): the composer's derivation minus window-specific
    /// phase — a row can't know whether THIS window's connect resolved, so a
    /// paired agent that isn't offline/failing reads as ready.
    @MainActor
    static func forTeammateRow(address: String, workspaceId: String) -> SharedAgentStatus {
        let connect = WorkspaceAgentConnectService.shared
        let paired = RemoteAgentManager.shared.remoteAgent(forAddress: address, workspaceId: workspaceId) != nil
        return derive(
            isServedForTeammate: false,
            callerLabel: nil,
            workspaceId: workspaceId,
            rosterLists: true,
            rosterHasLoaded: true,
            routerEnabled: OsaurusRouter.isEnabled,
            workspaceName: nil,
            presence: WorkspaceRosterStore.shared.presence(forAddress: address, workspaceId: workspaceId),
            isPaired: paired,
            isBoundToProvider: paired,
            isPairing: connect.isConnecting(address, workspaceId: workspaceId),
            connectFailure: connect.connectFailure(for: address, workspaceId: workspaceId),
            hasAttempted: connect.hasAttempted(address, workspaceId: workspaceId),
            phase: paired ? .connected : .idle
        )
    }

    /// Whether a connect can be (re)issued from this state.
    var offersRetry: Bool {
        switch self {
        case .offline, .notConnected: return true
        case .ready, .checking, .connecting, .unavailable, .readOnlyTeammate: return false
        }
    }

    /// Primary action label per the contract: `Connect` when nothing has
    /// been attempted yet, `Retry` after any failure or when offline.
    var actionLabel: String? {
        switch self {
        case .notConnected(_, let hasAttempted):
            return hasAttempted ? L("Retry") : L("Connect")
        case .offline:
            return L("Retry")
        case .ready, .checking, .connecting, .unavailable, .readOnlyTeammate:
            return nil
        }
    }

    /// SF Symbol for the status glyph.
    var symbolName: String {
        switch self {
        case .ready: return "lock.fill"
        case .checking, .connecting: return "arrow.triangle.2.circlepath"
        case .offline: return "moon.zzz.fill"
        case .notConnected: return "link.badge.plus"
        case .unavailable: return "person.crop.circle.badge.xmark"
        case .readOnlyTeammate: return "rectangle.3.group.fill"
        }
    }

    /// Which theme color role tints the glyph and chrome.
    enum Tint { case success, accent, warning, muted }
    var tint: Tint {
        switch self {
        case .ready: return .success
        case .checking, .connecting: return .accent
        case .notConnected: return .warning
        case .offline, .unavailable, .readOnlyTeammate: return .muted
        }
    }

    /// Short label for compact surfaces (sidebar subtitle, empty-state badge).
    var shortLabel: String {
        switch self {
        case .ready: return L("End-to-end encrypted")
        case .checking: return L("Checking…")
        case .connecting: return L("Connecting…")
        case .offline(let lastSeen):
            if let lastSeen {
                return String(format: L("Offline · last seen %@"), Self.relative(lastSeen))
            }
            return L("Offline")
        case .notConnected: return L("Not connected")
        case .unavailable: return L("Unavailable")
        case .readOnlyTeammate: return L("Read-only")
        }
    }

    /// Headline for the composer lock notice — one short line that names the
    /// agent and the state ("Couldn't connect to Weather Agent"). The reason
    /// lives in `detail`, so the notice reads as title + caption instead of
    /// one long wrapped sentence.
    func title(agentName: String) -> String {
        switch self {
        case .ready:
            return ""
        case .checking:
            return String(format: L("Checking access to %@…"), agentName)
        case .connecting:
            return String(format: L("Connecting to %@…"), agentName)
        case .offline:
            return String(format: L("%@ is offline"), agentName)
        case .notConnected(let reason, let hasAttempted):
            if hasAttempted, let reason, !reason.isEmpty {
                return String(format: L("Couldn't connect to %@"), agentName)
            }
            return String(format: L("%@ isn't connected yet"), agentName)
        case .unavailable:
            return String(format: L("%@ is unavailable"), agentName)
        case .readOnlyTeammate:
            return L("Read-only conversation")
        }
    }

    /// Secondary line for the composer lock notice: the reason and what the
    /// user can expect. `hostName` is the teammate's name (or nil). nil when
    /// the title says it all.
    func detail(agentName: String, hostName: String?) -> String? {
        switch self {
        case .checking:
            return L("Sending resumes automatically after verification. Your history and draft remain available.")
        case .ready, .connecting:
            return nil
        case .offline(let lastSeen):
            let host = hostName.map { String(format: L("%@'s Osaurus"), $0) } ?? L("its host")
            var text = String(
                format: L("You can read this conversation; new messages send once %@ is back online."),
                host
            )
            if let lastSeen {
                text += " " + String(format: L("Last seen %@."), Self.relative(lastSeen))
            }
            return text
        case .notConnected(let reason, _):
            if let reason, !reason.isEmpty { return Self.sentence(reason) }
            return L("Connect to start chatting over the encrypted relay.")
        case .unavailable(let reason, _):
            return Self.sentence(reason) + " " + L("You can still read this conversation.")
        case .readOnlyTeammate(let callerName):
            return String(
                format: L("%@'s conversation with %@ through your workspace. Replying here would inject into their chat."),
                callerName ?? L("A teammate"), agentName
            )
        }
    }

    /// `title` and `detail` as one sentence, for tooltips and accessibility.
    func message(agentName: String, hostName: String?) -> String {
        let title = title(agentName: agentName)
        guard let detail = detail(agentName: agentName, hostName: hostName) else { return title }
        return "\(title) — \(detail)"
    }

    /// Capitalize the first letter and make sure the fragment ends with a
    /// period, so reasons from different sources read as one sentence
    /// after the em dash.
    static func sentence(_ fragment: String) -> String {
        var text = fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first else { return text }
        text.replaceSubrange(text.startIndex...text.startIndex, with: String(first).uppercased())
        if let last = text.last, !".!?…".contains(last) { text += "." }
        return text
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
