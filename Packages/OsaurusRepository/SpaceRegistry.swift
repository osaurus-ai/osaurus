//
//  SpaceRegistry.swift
//  osaurus
//
//  Spaces are named, isolated Osaurus environments. The Default Space is
//  `~/.osaurus`; every other Space keeps its data, parked preferences, and
//  (in OsaurusCore) its own Keychain entries under `~/.osaurus-spaces/<id>/`.
//  This file is the shared, Foundation-only half: the registry document and
//  the active-root resolution that both the app and the CLI use.
//

import Foundation

public struct OsaurusSpace: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var createdAt: Date

    public init(id: String, name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// Work the next launch of a bundle applies before any app code runs, so
/// nothing destructive races live services.
public struct OsaurusSpacePendingOperation: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case reset
        case delete
    }

    public var kind: Kind
    public var spaceId: String

    public init(kind: Kind, spaceId: String) {
        self.kind = kind
        self.spaceId = spaceId
    }
}

/// A preferences swap that started but has not been recorded as finished.
public struct OsaurusSpaceSwap: Codable, Equatable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

public struct OsaurusSpaceRegistryDocument: Codable, Equatable, Sendable {
    public var version: Int
    public var spaces: [OsaurusSpace]
    /// Bundle id -> active Space id. Keyed per bundle so a dev or proof
    /// build switching Spaces never changes which Space the installed app
    /// opens.
    public var active: [String: String]
    /// Bundle id -> Space whose preferences currently sit in that bundle's
    /// live `UserDefaults` domain.
    public var defaultsOwner: [String: String]
    public var pending: [String: [OsaurusSpacePendingOperation]]
    public var swapInProgress: [String: OsaurusSpaceSwap]

    public init(
        version: Int = 1,
        spaces: [OsaurusSpace] = [],
        active: [String: String] = [:],
        defaultsOwner: [String: String] = [:],
        pending: [String: [OsaurusSpacePendingOperation]] = [:],
        swapInProgress: [String: OsaurusSpaceSwap] = [:]
    ) {
        self.version = version
        self.spaces = spaces
        self.active = active
        self.defaultsOwner = defaultsOwner
        self.pending = pending
        self.swapInProgress = swapInProgress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        spaces = try c.decodeIfPresent([OsaurusSpace].self, forKey: .spaces) ?? []
        active = try c.decodeIfPresent([String: String].self, forKey: .active) ?? [:]
        defaultsOwner = try c.decodeIfPresent([String: String].self, forKey: .defaultsOwner) ?? [:]
        pending = try c.decodeIfPresent([String: [OsaurusSpacePendingOperation]].self, forKey: .pending) ?? [:]
        swapInProgress = try c.decodeIfPresent([String: OsaurusSpaceSwap].self, forKey: .swapInProgress) ?? [:]
    }

    public func space(id: String) -> OsaurusSpace? {
        spaces.first { $0.id == id }
    }

    /// The bundle's active Space, falling back to Default when the recorded
    /// id no longer names a known Space.
    public func activeSpaceId(bundleId: String) -> String {
        guard let id = active[bundleId], id != SpaceRegistry.defaultSpaceId, space(id: id) != nil else {
            return SpaceRegistry.defaultSpaceId
        }
        return id
    }

    public func defaultsOwnerId(bundleId: String) -> String {
        defaultsOwner[bundleId] ?? SpaceRegistry.defaultSpaceId
    }

    /// Bundles other than `bundleId` whose active Space is `spaceId`.
    public func otherBundlesUsing(spaceId: String, excluding bundleId: String) -> [String] {
        active.compactMap { key, value in
            key != bundleId && value == spaceId ? key : nil
        }.sorted()
    }
}

public enum SpaceRegistry {
    public static let defaultSpaceId = "default"
    public static let fallbackBundleId = "com.dinoki.osaurus"
    /// Inherited by child processes (plugins, harnesses, the bundled CLI) so
    /// they resolve the same root as the app that spawned them.
    public static let activeSpaceEnvironmentKey = "OSAURUS_SPACE_ID"

    /// Test-only registry directory override.
    public nonisolated(unsafe) static var overrideDirectory: URL?

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cachedActiveSpaceId: String?

    // MARK: - Paths

    /// `~/.osaurus-spaces/`, deliberately outside `~/.osaurus` so a Default
    /// factory reset never deletes other Spaces.
    public static func directory() -> URL {
        if let overrideDirectory { return overrideDirectory }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".osaurus-spaces", isDirectory: true)
    }

    public static func registryFile() -> URL {
        directory().appendingPathComponent("registry.json")
    }

    /// Per-Space folder holding `data/` and `preferences/`. Default has one
    /// too, for its parked preferences only; its data stays in `~/.osaurus`.
    public static func spaceDirectory(for spaceId: String) -> URL {
        directory().appendingPathComponent(spaceId, isDirectory: true)
    }

    /// Data root of a non-Default Space; nil for Default.
    public static func dataRoot(for spaceId: String) -> URL? {
        guard spaceId != defaultSpaceId, isValidSpaceId(spaceId) else { return nil }
        return spaceDirectory(for: spaceId).appendingPathComponent("data", isDirectory: true)
    }

    public static func preferencesFile(spaceId: String, bundleId: String) -> URL {
        spaceDirectory(for: spaceId)
            .appendingPathComponent("preferences", isDirectory: true)
            .appendingPathComponent("\(bundleId).plist")
    }

    /// Ids are lowercase UUIDs, which keeps an id read from the environment
    /// or a hand-edited registry from escaping `directory()`.
    public static func isValidSpaceId(_ id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        return uuid.uuidString.lowercased() == id
    }

    public static func newSpaceId() -> String {
        UUID().uuidString.lowercased()
    }

    public static var currentBundleId: String {
        Bundle.main.bundleIdentifier ?? fallbackBundleId
    }

    // MARK: - Document IO

    /// The registry, or nil when no Space was ever created. Throws when the
    /// file exists but cannot be decoded, so callers never overwrite a
    /// registry they could not read.
    public static func load() throws -> OsaurusSpaceRegistryDocument? {
        let url = registryFile()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OsaurusSpaceRegistryDocument.self, from: data)
    }

    public static func save(_ document: OsaurusSpaceRegistryDocument) throws {
        try FileManager.default.createDirectory(at: directory(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: registryFile(), options: .atomic)
    }

    // MARK: - Active Space

    /// The Space this process runs in, resolved once and cached. Test-root
    /// launches always run in Default so they never read or write Spaces.
    public static func activeSpaceId() -> String {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cachedActiveSpaceId { return cachedActiveSpaceId }
        let resolved = resolveActiveSpaceId()
        cachedActiveSpaceId = resolved
        return resolved
    }

    /// Data root of the active Space, or nil when it is Default.
    public static func activeDataRoot() -> URL? {
        dataRoot(for: activeSpaceId())
    }

    public static var isDefaultActive: Bool {
        activeSpaceId() == defaultSpaceId
    }

    /// Fixes the process's Space after launch preparation and exports it to
    /// child processes.
    public static func pinActiveSpace(_ spaceId: String) {
        let id = (spaceId == defaultSpaceId || isValidSpaceId(spaceId)) ? spaceId : defaultSpaceId
        cacheLock.lock()
        cachedActiveSpaceId = id
        cacheLock.unlock()
        setenv(activeSpaceEnvironmentKey, id, 1)
    }

    public static func _resetCacheForTesting() {
        cacheLock.lock()
        cachedActiveSpaceId = nil
        cacheLock.unlock()
    }

    public static var testRootIsSet: Bool {
        guard let raw = getenv("OSAURUS_TEST_ROOT") else { return false }
        return !String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Test harnesses must never pick up the real registry of the user's app.
    public static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        let name = ProcessInfo.processInfo.processName
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || name == "xctest"
            || name == "swiftpm-testing-helper"
            || Bundle.main.bundlePath.hasSuffix(".xctest")
    }

    /// True when this process may read and change Spaces at all.
    public static var isEnabled: Bool {
        overrideDirectory != nil || !(testRootIsSet || isRunningTests)
    }

    private static func resolveActiveSpaceId() -> String {
        guard isEnabled else { return defaultSpaceId }
        let inherited = getenv(activeSpaceEnvironmentKey).map { String(cString: $0) }
        return resolveActiveSpaceId(
            inheritedSpaceId: inherited,
            document: (try? load()) ?? nil,
            bundleId: currentBundleId
        )
    }

    /// Resolution rule for an enabled process: an id inherited from the
    /// parent app wins, then the registry's entry for this bundle, then
    /// Default.
    public static func resolveActiveSpaceId(
        inheritedSpaceId: String?,
        document: OsaurusSpaceRegistryDocument?,
        bundleId: String
    ) -> String {
        if let id = inheritedSpaceId, id == defaultSpaceId || isValidSpaceId(id) {
            return id
        }
        return document?.activeSpaceId(bundleId: bundleId) ?? defaultSpaceId
    }
}
