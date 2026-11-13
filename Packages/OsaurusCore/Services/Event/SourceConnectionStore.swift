//
//  SourceConnectionStore.swift
//  osaurus
//
//  The source connections automations read from, one JSON file each under
//  `~/.osaurus/connections/<id>.json`. Deleting a connection that an
//  automation or the Email channel still uses is refused; the users are
//  named instead.
//

import Foundation
import Observation

extension Notification.Name {
    public static let sourceConnectionsChanged = Notification.Name("osaurusSourceConnectionsChanged")
}

@Observable
@MainActor
public final class SourceConnectionStore {
    public static let shared = SourceConnectionStore()

    public private(set) var connections: [SourceConnection] = []

    @ObservationIgnored private let persistsToDisk: Bool
    @ObservationIgnored private var loaded = false
    /// Who uses a connection; the live store asks the event manager.
    @ObservationIgnored var dependents: @MainActor (String) -> [OsaurusEvent] = { id in
        EventManager.shared.events.filter { $0.source.connectionId == id }
    }
    /// Channels that read a connection (the Email channel), by name.
    @ObservationIgnored var channelDependents: @MainActor (String) -> [String] = { id in
        EmailChannelConfigurationStore.load().account(connectionId: id) == nil ? [] : [L("the Email channel")]
    }

    init(persistsToDisk: Bool = true) {
        self.persistsToDisk = persistsToDisk
    }

    public enum DeleteResult: Equatable, Sendable {
        case deleted
        case notFound
        /// Automations still use it; their names.
        case inUse([String])
    }

    // MARK: - Queries

    public func connection(id: String) -> SourceConnection? {
        loadIfNeeded()
        return connections.first { $0.id == id.lowercased() || $0.id == id }
    }

    public func connections(of types: [SourceConnectionType]) -> [SourceConnection] {
        loadIfNeeded()
        return connections.filter { types.contains($0.type) }
    }

    public func reload() {
        guard persistsToDisk else { return }
        connections = Self.loadAll()
        loaded = true
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if persistsToDisk { connections = Self.loadAll() }
    }

    // MARK: - CRUD

    @discardableResult
    public func save(_ connection: SourceConnection) -> SourceConnection {
        loadIfNeeded()
        var saved = connection
        saved.updatedAt = Date()
        if let index = connections.firstIndex(where: { $0.id == saved.id }) {
            connections[index] = saved
        } else {
            connections.append(saved)
        }
        connections.sort { $0.createdAt < $1.createdAt }
        if persistsToDisk { Self.write(saved) }
        NotificationCenter.default.post(name: .sourceConnectionsChanged, object: nil)
        return saved
    }

    /// Removes the connection and its secrets unless an automation uses it.
    @discardableResult
    public func delete(id: String) -> DeleteResult {
        loadIfNeeded()
        guard let connection = connection(id: id) else { return .notFound }
        let users = dependents(connection.id).map(\.name) + channelDependents(connection.id)
        guard users.isEmpty else { return .inUse(users) }
        connections.removeAll { $0.id == connection.id }
        SourceCredentialVault.deleteAll(connectionId: connection.id, type: connection.type)
        if persistsToDisk { try? FileManager.default.removeItem(at: Self.fileURL(for: connection.id)) }
        NotificationCenter.default.post(name: .sourceConnectionsChanged, object: nil)
        return .deleted
    }

    // MARK: - Files

    static var directory: URL {
        let dir = OsaurusPaths.sourceConnections()
        OsaurusPaths.ensureExistsSilent(dir)
        return dir
    }

    static func fileURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    /// Every connection on disk. A file that does not decode is skipped
    /// and logged, never deleted.
    static func loadAll() -> [SourceConnection] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var out: [SourceConnection] = []
        for file in files where file.pathExtension == "json" {
            do {
                out.append(try EventStore.decoder.decode(SourceConnection.self, from: Data(contentsOf: file)))
            } catch {
                print("[Osaurus] Failed to load source connection \(file.lastPathComponent): \(error)")
            }
        }
        return out.sorted { $0.createdAt < $1.createdAt }
    }

    static func write(_ connection: SourceConnection) {
        do {
            try EventStore.encoder.encode(connection).write(to: fileURL(for: connection.id), options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save source connection \(connection.id): \(error)")
        }
    }
}
