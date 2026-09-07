import Foundation

public enum CoordinatorPathError: Error, Equatable, LocalizedError {
    case emptyRoot

    public var errorDescription: String? {
        switch self {
        case .emptyRoot:
            return "Coordinator root cannot be empty."
        }
    }
}

public struct CoordinatorPaths: Equatable, Sendable {
    public static let environmentKey = "OSAURUS_COORD_ROOT"
    public static let defaultRootPath = "/tmp/osaurus-coord"

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public init(rootPath: String) throws {
        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CoordinatorPathError.emptyRoot }
        self.init(root: URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath))
    }

    public static func resolve(
        cliRoot: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CoordinatorPaths {
        if let cliRoot {
            return try CoordinatorPaths(rootPath: cliRoot)
        }
        if let envRoot = environment[environmentKey], !envRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try CoordinatorPaths(rootPath: envRoot)
        }
        return try CoordinatorPaths(rootPath: defaultRootPath)
    }

    public var stateDirectory: URL { root.appendingPathComponent("state", isDirectory: true) }
    public var locksDirectory: URL { root.appendingPathComponent("locks", isDirectory: true) }
    public var worktreesDirectory: URL { root.appendingPathComponent("worktrees", isDirectory: true) }
    public var artifactsDirectory: URL { root.appendingPathComponent("artifacts", isDirectory: true) }
    public var evidenceDirectory: URL { root.appendingPathComponent("evidence", isDirectory: true) }
    public var lanesDirectory: URL { root.appendingPathComponent("lanes", isDirectory: true) }

    public var statusFile: URL { stateDirectory.appendingPathComponent("status.json") }
    public var featureFlagsFile: URL { stateDirectory.appendingPathComponent("feature-flags.json") }
    public var lanesFile: URL { stateDirectory.appendingPathComponent("lanes.json") }
    public var pauseFile: URL { stateDirectory.appendingPathComponent("pause.json") }
    public var stopFile: URL { stateDirectory.appendingPathComponent("stop.json") }

    public func laneDirectory(named lane: String) -> URL {
        lanesDirectory.appendingPathComponent(Self.fileComponent(for: lane), isDirectory: true)
    }

    public func lockFile(for resource: String) -> URL {
        locksDirectory.appendingPathComponent(Self.fileComponent(for: resource)).appendingPathExtension("lock.json")
    }

    public static func fileComponent(for value: String) -> String {
        var output = ""
        for byte in value.utf8 {
            let scalar = UnicodeScalar(byte)
            if CharacterSet.alphanumerics.contains(scalar) || byte == 45 || byte == 46 || byte == 95 {
                output.append(Character(scalar))
            } else {
                output += String(format: "%%%02X", byte)
            }
        }
        // A component of only "." or ".." resolves to the current/parent directory,
        // which would let a name escape its intended container (e.g.
        // `laneDirectory(named: "..")` resolving above `lanes/`). Percent-encode the
        // dots so the component stays a literal child name.
        if output == "." || output == ".." {
            return output.replacingOccurrences(of: ".", with: "%2E")
        }
        return output.isEmpty ? "_" : output
    }
}

enum CoordinatorFilePermissions {
    static let directoryMode = 0o700
    static let fileMode = 0o600

    static var directoryAttributes: [FileAttributeKey: Any] {
        [.posixPermissions: NSNumber(value: directoryMode)]
    }

    static func applyDirectoryPermissions(to url: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes(directoryAttributes, ofItemAtPath: url.path)
    }

    static func applyFilePermissions(to url: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: fileMode)], ofItemAtPath: url.path)
    }
}
