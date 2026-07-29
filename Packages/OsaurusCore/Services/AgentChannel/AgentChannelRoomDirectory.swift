//
//  AgentChannelRoomDirectory.swift
//  osaurus
//
//  Session cache of human-readable room metadata (name, conversation type)
//  per (connection, room) route. Destination rows read it synchronously and
//  fall back to raw ids while a connection is still loading or failed to
//  load — presentation only, never authorization.
//

import Foundation

@MainActor
final class AgentChannelRoomDirectory: ObservableObject {
    static let shared = AgentChannelRoomDirectory()

    /// Bumped whenever cached descriptors change so observing views refresh.
    @Published private(set) var version = 0

    private var descriptors: [String: AgentChannelRoomDescriptor] = [:]
    private var loadedConnections: Set<String> = []
    private var inflightConnections: Set<String> = []

    private let listSpaces: (String) async throws -> [[String: Any]]
    private let listRooms: (String, String) async throws -> [[String: Any]]

    init(
        listSpaces: ((String) async throws -> [[String: Any]])? = nil,
        listRooms: ((String, String) async throws -> [[String: Any]])? = nil
    ) {
        self.listSpaces =
            listSpaces
            ?? { connectionId in
                try await AgentChannelConnectionService.shared.listSpaces(connectionId: connectionId)
            }
        self.listRooms =
            listRooms
            ?? { connectionId, spaceId in
                try await AgentChannelConnectionService.shared.listRooms(
                    connectionId: connectionId,
                    spaceId: spaceId
                )
            }
    }

    /// Cached metadata for one route, if that connection has loaded.
    func descriptor(connectionId: String, roomId: String) -> AgentChannelRoomDescriptor? {
        descriptors[Self.key(connectionId: connectionId, roomId: roomId)]
    }

    /// Kick off room discovery for any connection not yet loaded this
    /// session. Cheap to call from `onAppear`; already-loaded and inflight
    /// connections are skipped.
    func prepare(connectionIds: some Sequence<String>) {
        for connectionId in Set(connectionIds) {
            let normalized = AgentChannelConnection.normalizedId(connectionId)
            guard !normalized.isEmpty,
                !loadedConnections.contains(normalized),
                !inflightConnections.contains(normalized)
            else { continue }
            inflightConnections.insert(normalized)
            Task { await load(connectionId: normalized) }
        }
    }

    /// Drop cached load markers and immediately re-resolve previously loaded
    /// connections — called after a channel's configuration sheet closes,
    /// when allowlists or credentials may have changed. Cached descriptors
    /// keep serving rows until fresh results replace them.
    func invalidate() {
        let toReload = loadedConnections
        loadedConnections.removeAll()
        prepare(connectionIds: toReload)
    }

    private func load(connectionId: String) async {
        defer { inflightConnections.remove(connectionId) }
        do {
            let spaces = try await listSpaces(connectionId)
            var loaded: [String: AgentChannelRoomDescriptor] = [:]
            for space in spaces.prefix(10) {
                guard let spaceId = space["id"] as? String, !spaceId.isEmpty else { continue }
                let rows = try await listRooms(connectionId, spaceId)
                for row in rows {
                    guard let id = row["id"] as? String, !id.isEmpty else { continue }
                    let kindString = (row["kind"] as? String) ?? ""
                    // Skip synthetic rows (e.g. Slack's pagination notice).
                    guard kindString != "notice" else { continue }
                    let name = (row["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
                    loaded[Self.key(connectionId: connectionId, roomId: id)] =
                        AgentChannelRoomDescriptor(
                            name: name,
                            kind: .from(providerKind: kindString)
                        )
                }
            }
            descriptors.merge(loaded) { _, new in new }
            loadedConnections.insert(connectionId)
            version += 1
        } catch {
            // Best-effort: rows keep their raw-id fallback. Not marking the
            // connection loaded lets a later `prepare` retry.
        }
    }

    private static func key(connectionId: String, roomId: String) -> String {
        "\(AgentChannelConnection.normalizedId(connectionId))\u{1}\(AgentChannelConnection.normalizedId(roomId))"
    }
}
