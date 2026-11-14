//
//  AgentChannelAutoDestinationResolver.swift
//  osaurus
//
//  Zero-config proactive destinations. A user who connected a native
//  channel already told Osaurus everything a proactive destination needs:
//  which rooms the bot may WRITE to (the write allowlist) and which agent
//  answers there (its channel-message events). This resolver derives ask-first
//  (`confirm` mode) destination bindings from that existing configuration
//  so proactive posting works without a separate setup form.
//
//  Security invariants:
//  - Derived bindings grant NO new write capability: they exist only for
//    rooms the operator already write-allowlisted, on connections with
//    write access enabled, and every send still passes the full publish
//    authorization matrix (kill switch, allowlists, rate policy).
//  - Derived bindings are ALWAYS `confirm` mode — an approval card on
//    attended runs, a queued outbox item on unattended runs. Autonomous
//    sending remains an explicit, acknowledged stored-binding opt-in.
//  - A stored binding for the same (agent, connection, room) suppresses
//    the derived one, so operator customization — including turning a
//    room OFF — always wins.
//

import Foundation

/// One native provider's inputs to automatic destination derivation.
struct AgentChannelAutoDestinationSource: Sendable {
    let connectionId: String
    let displayName: String
    /// Whether a credential is saved; a channel that cannot authenticate
    /// cannot send, so it derives nothing.
    let hasCredential: Bool
    let writeEnabled: Bool
    let writableRoomIds: [String]
    let listeners: ChannelEventListeners

    init(
        connectionId: String,
        displayName: String,
        hasCredential: Bool,
        writeEnabled: Bool,
        writableRoomIds: [String],
        listeners: ChannelEventListeners
    ) {
        self.connectionId = AgentChannelConnection.normalizedId(connectionId)
        self.displayName = displayName
        self.hasCredential = hasCredential
        self.writeEnabled = writeEnabled
        self.writableRoomIds = AgentChannelConnection.normalizedIds(writableRoomIds)
        self.listeners = listeners
    }
}

enum AgentChannelAutoDestinationResolver {
    static let bindingIdPrefix = "auto-"

    /// Whether a binding id names a derived (automatic) destination rather
    /// than a stored one. Purely cosmetic — authorization never branches on
    /// it — but the UI uses it to badge rows as "Automatic".
    static func isAutomaticBindingId(_ id: String) -> Bool {
        AgentChannelBinding.normalizedBindingId(id).hasPrefix(bindingIdPrefix)
    }

    /// Stored configuration plus derived automatic destinations. This is
    /// the view every proactive read point uses (tool exposure, system
    /// prompt, publish authorization), so removing a room from the write
    /// allowlist — or disabling write access — makes its automatic
    /// destination vanish everywhere at once, including for already-queued
    /// approvals (which then refuse with `binding_removed`).
    static func effectiveConfiguration(
        stored: AgentChannelConfiguration = AgentChannelConfigurationStore.load(),
        sources: [AgentChannelAutoDestinationSource]? = nil
    ) -> AgentChannelConfiguration {
        var configuration = stored
        configuration.bindings += derivedBindings(
            sources: sources ?? liveSources(),
            storedBindings: stored.bindings
        )
        return configuration
    }

    /// Derive automatic bindings for every (agent answering a room, writable
    /// room) pair that the operator has not customized with a stored binding.
    static func derivedBindings(
        sources: [AgentChannelAutoDestinationSource],
        storedBindings: [AgentChannelBinding]
    ) -> [AgentChannelBinding] {
        let storedIds = Set(storedBindings.map(\.id))
        let customizedRoutes = Set(
            storedBindings.map { RouteKey(agentId: $0.agentId, connectionId: $0.connectionId, roomId: $0.roomId) }
        )

        var derived: [AgentChannelBinding] = []
        for source in sources {
            guard source.hasCredential, source.writeEnabled, !source.listeners.isEmpty else {
                continue
            }
            for roomId in source.writableRoomIds {
                // Workspace-agent events answer on the host machine; they
                // never derive a local publish destination.
                for agentId in source.listeners.agentIds(answering: roomId) {
                    let route = RouteKey(
                        agentId: agentId,
                        connectionId: source.connectionId,
                        roomId: roomId
                    )
                    guard !customizedRoutes.contains(route) else { continue }
                    let binding = AgentChannelBinding(
                        id: automaticBindingId(
                            connectionId: source.connectionId,
                            roomId: roomId,
                            agentId: agentId
                        ),
                        agentId: agentId,
                        connectionId: source.connectionId,
                        roomId: roomId,
                        label: "\(source.displayName) · \(roomId)",
                        allowedSources: AgentChannelBindingRunSource.allCases,
                        // Never anything but `confirm`: automatic routes must
                        // keep a human on every send.
                        outboundMode: .confirm,
                        enabled: true
                    )
                    // A stored binding that happens to use this id wins.
                    guard !storedIds.contains(binding.id) else { continue }
                    derived.append(binding)
                }
            }
        }
        return derived
    }

    /// Deterministic, stable id for an automatic destination. The agent
    /// suffix disambiguates multiple agents answering the same room; ids
    /// stay stable across launches so queued outbox items keep resolving.
    static func automaticBindingId(
        connectionId: String,
        roomId: String,
        agentId: UUID
    ) -> String {
        let agentSuffix = agentId.uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return AgentChannelBinding.normalizedBindingId(
            "\(bindingIdPrefix)\(connectionId)-\(roomId)-\(agentSuffix)"
        )
    }

    /// Live derivation inputs for the native providers. The write
    /// allowlists come from the same resolved connection views the publish
    /// path enforces at send time, so a derived destination can never
    /// advertise a room the send-time policy would refuse.
    ///
    /// Credential availability comes from the non-blocking
    /// `AgentChannelCredentialAvailability` snapshot rather than live
    /// Keychain/filesystem probes: this function is reached from MainActor
    /// paths (prompt preview composition, Settings reloads) and a
    /// synchronous `SecItemCopyMatching` under securityd contention was a
    /// measured multi-second main-thread hang (Sentry APPLE-MACOS-1B5).
    static func liveSources() -> [AgentChannelAutoDestinationSource] {
        let service = AgentChannelConnectionService.shared
        let availability = AgentChannelCredentialAvailability.shared
        var natives: [(id: String, kind: AgentChannelKind, hasCredential: Bool)] = [
            AgentChannelKind.discord, .slack, .telegram,
        ].flatMap { kind in
            ChannelAccounts.accounts(kind: kind).map {
                ($0.connectionId, kind, availability.hasCredential(connectionId: $0.connectionId))
            }
        }
        natives += [
            // iMessage has no token; a verified helper is what makes sends
            // possible, so it plays the credential role here.
            (AgentChannelConnection.nativeIMessageConnectionId, .imessage, availability.hasCredential(.imessage)),
            // WhatsApp's credential is the helper's linked Web session.
            (AgentChannelConnection.nativeWhatsAppConnectionId, .whatsapp, availability.hasCredential(.whatsapp)),
        ]
        return natives.compactMap { native in
            guard let view = try? service.resolvedConnectionView(id: native.id) else { return nil }
            return AgentChannelAutoDestinationSource(
                connectionId: view.id,
                displayName: view.name,
                hasCredential: native.hasCredential,
                writeEnabled: view.writeEnabled,
                writableRoomIds: view.writeRoomAllowlist,
                listeners: EventManager.channelListeners(kind: native.kind, connectionId: native.id)
            )
        }
    }

    private struct RouteKey: Hashable {
        let agentId: UUID
        let connectionId: String
        let roomId: String
    }
}
