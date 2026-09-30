import Foundation

public struct CoordinatorFeatureFlags: Codable, Equatable, Sendable {
    public var flags: [String: Bool]

    public init(flags: [String: Bool]) {
        self.flags = flags
    }

    public static let defaults = CoordinatorFeatureFlags(flags: [
        "coordinator": true,
        "conflict-proof": false,
        "gate-main": false,
        "heartbeat": false,
        "nudge": false,
        "promote": false,
        "reviewer-summary": false,
    ])

    public subscript(name: String) -> Bool? {
        get { flags[name] }
        set { flags[name] = newValue }
    }
}

public struct CoordinatorFeatureFlagsStore {
    public let paths: CoordinatorPaths
    private let fileManager: FileManager

    public init(paths: CoordinatorPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func load() throws -> CoordinatorFeatureFlags {
        guard fileManager.fileExists(atPath: paths.featureFlagsFile.path) else {
            return CoordinatorFeatureFlags.defaults
        }
        let data = try Data(contentsOf: paths.featureFlagsFile)
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(CoordinatorFeatureFlags.self, from: data)
        } catch is DecodingError {
            // An undecodable (truncated / hand-edited / partially written) file
            // degrades to defaults, mirroring the absent-file branch above, so the
            // read-only `coord status` diagnostic keeps working and `feature-flags
            // set` can repair the file. Genuine I/O errors from Data(contentsOf:)
            // still propagate.
            return CoordinatorFeatureFlags.defaults
        }
    }

    @discardableResult
    public func set(_ name: String, enabled: Bool) throws -> CoordinatorFeatureFlags {
        var flags = try load()
        flags[name] = enabled
        try save(flags)
        return flags
    }

    public func save(_ flags: CoordinatorFeatureFlags) throws {
        try fileManager.createDirectory(
            at: paths.stateDirectory,
            withIntermediateDirectories: true,
            attributes: CoordinatorFilePermissions.directoryAttributes
        )
        try CoordinatorFilePermissions.applyDirectoryPermissions(to: paths.stateDirectory, fileManager: fileManager)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(flags)
        try data.write(to: paths.featureFlagsFile, options: .atomic)
        try CoordinatorFilePermissions.applyFilePermissions(to: paths.featureFlagsFile, fileManager: fileManager)
    }
}
