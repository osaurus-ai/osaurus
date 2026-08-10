//
//  BrowserSessionCatalog.swift
//  OsaurusCore — Native Browser Use
//
//  Persistent metadata for native browser sessions. One record per agent:
//  the WebKit profile UUID that backs its `WKWebsiteDataStore`, the last page
//  it visited, and the OBSERVED authentication status per service. The catalog
//  is the source of truth the Browser settings tab renders and the migration
//  path writes into — the WebKit on-disk store itself is owned by
//  `WKWebsiteDataStore(forIdentifier:)`.
//
//  Authentication is represented as an OBSERVED status, never inferred from
//  cookie presence alone: a service is `signInRequired` when a navigation was
//  redirected to a login page, `observedSignedIn` once the user completed the
//  sign-in window (or a page after login loaded), and `unknown` otherwise.
//

import Foundation

/// Observed sign-in status for one service (host) within a session.
public enum BrowserAuthStatus: String, Codable, Sendable, Equatable {
    /// Never observed — cookie state is genuinely unknown.
    case unknown
    /// A navigation was redirected to a login page for this host.
    case signInRequired
    /// The user completed sign-in (via the login window) or a post-login page
    /// loaded for this host.
    case observedSignedIn

    public var displayLabel: String {
        switch self {
        case .unknown: return L("Unknown")
        case .signInRequired: return L("Sign-in needed")
        case .observedSignedIn: return L("Signed in")
        }
    }
}

/// One persisted browser-session record, keyed by agent id.
public struct BrowserSessionRecord: Codable, Sendable, Equatable, Identifiable {
    /// The owning agent's id (the catalog key). `Identifiable` on it so the
    /// settings list can render rows directly.
    public var agentId: UUID
    /// The WebKit profile UUID backing this session's `WKWebsiteDataStore`.
    public var profileId: UUID
    /// True once at least one page has loaded in this run (the session has a
    /// live WebView attached). Persisted `false`; set at runtime by the manager.
    public var isActive: Bool
    /// Last host visited (for the settings row subtitle + restore).
    public var lastDomain: String?
    /// Last page title (settings row subtitle).
    public var lastTitle: String?
    /// Last full URL, used to restore the session to where it left off.
    public var lastURL: String?
    /// Last time the session did anything (navigate / act).
    public var lastActivity: Date?
    /// Observed sign-in status per service host.
    public var services: [String: BrowserAuthStatus]

    public var id: UUID { agentId }

    public init(
        agentId: UUID,
        profileId: UUID,
        isActive: Bool = false,
        lastDomain: String? = nil,
        lastTitle: String? = nil,
        lastURL: String? = nil,
        lastActivity: Date? = nil,
        services: [String: BrowserAuthStatus] = [:]
    ) {
        self.agentId = agentId
        self.profileId = profileId
        self.isActive = isActive
        self.lastDomain = lastDomain
        self.lastTitle = lastTitle
        self.lastURL = lastURL
        self.lastActivity = lastActivity
        self.services = services
    }
}

/// File-backed catalog of `BrowserSessionRecord`s. MainActor-confined with a
/// synchronous in-memory cache, mirroring `ComputerUsePolicyStore`.
@MainActor
public enum BrowserSessionCatalog {
    /// Test override for the persistence directory.
    public static var overrideDirectory: URL?

    private static var cached: [UUID: BrowserSessionRecord]?

    /// All records in a stable order (most-recent activity first).
    public static func allRecords() -> [BrowserSessionRecord] {
        load().values.sorted { lhs, rhs in
            (lhs.lastActivity ?? .distantPast) > (rhs.lastActivity ?? .distantPast)
        }
    }

    public static func record(for agentId: UUID) -> BrowserSessionRecord? {
        load()[agentId]
    }

    /// Return the existing profile UUID for an agent, or mint + persist one.
    public static func profileId(for agentId: UUID) -> UUID {
        if let existing = load()[agentId] { return existing.profileId }
        let record = BrowserSessionRecord(agentId: agentId, profileId: UUID())
        upsert(record)
        return record.profileId
    }

    /// Insert or replace a record (whole-record write).
    public static func upsert(_ record: BrowserSessionRecord) {
        var map = load()
        map[record.agentId] = record
        cached = map
        persist(map)
    }

    /// Mutate a record in place, creating it (with a fresh profile) if absent.
    public static func update(agentId: UUID, _ mutate: (inout BrowserSessionRecord) -> Void) {
        var map = load()
        var record = map[agentId] ?? BrowserSessionRecord(agentId: agentId, profileId: UUID())
        mutate(&record)
        map[agentId] = record
        cached = map
        persist(map)
    }

    /// Remove a record entirely (agent deletion / reset that mints a new UUID).
    public static func remove(agentId: UUID) {
        var map = load()
        guard map.removeValue(forKey: agentId) != nil else { return }
        cached = map
        persist(map)
    }

    /// Idempotently seed a record for an agent from a migrated profile UUID.
    /// Does nothing when the agent already has a record (migration must not
    /// clobber a session the user has already used natively).
    @discardableResult
    public static func migrateProfile(_ profileId: UUID, forAgent agentId: UUID) -> Bool {
        if load()[agentId] != nil { return false }
        upsert(BrowserSessionRecord(agentId: agentId, profileId: profileId))
        return true
    }

    /// Wipe the whole catalog (factory reset).
    public static func removeAll() {
        cached = [:]
        persist([:])
    }

    // MARK: - Persistence

    private static func load() -> [UUID: BrowserSessionRecord] {
        if let cached { return cached }
        let url = fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            cached = [:]
            return [:]
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let records = try decoder.decode([BrowserSessionRecord].self, from: Data(contentsOf: url))
            let map = Dictionary(uniqueKeysWithValues: records.map { ($0.agentId, $0) })
            cached = map
            return map
        } catch {
            print("[Osaurus] Failed to load BrowserSessionCatalog: \(error)")
            cached = [:]
            return [:]
        }
    }

    /// Serial write queue: the concurrent global queue could land two rapid
    /// saves on disk in reverse order, persisting stale records.
    private static let persistQueue = DispatchQueue(
        label: "com.osaurus.browser.catalog-persist", qos: .utility)

    private static func persist(_ map: [UUID: BrowserSessionRecord]) {
        let url = fileURL()
        let records = Array(map.values)
        persistQueue.async {
            OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(records).write(to: url, options: [.atomic])
            } catch {
                print("[Osaurus] Failed to save BrowserSessionCatalog: \(error)")
            }
        }
    }

    /// Test hook: block until every queued write has hit disk.
    public static func flushWritesForTests() {
        persistQueue.sync {}
    }

    private static func fileURL() -> URL {
        if let dir = overrideDirectory {
            return dir.appendingPathComponent("browser-sessions.json")
        }
        return OsaurusPaths.browserSessionsFile()
    }

    /// Test hook: drop the in-memory cache so the next read re-decodes.
    public static func resetCacheForTests() {
        cached = nil
    }
}
