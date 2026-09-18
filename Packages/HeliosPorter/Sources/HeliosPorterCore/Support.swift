import Foundation

enum HeliosPorterSupport {
    static let serverTodoMarkers = [
        "TODO(Helios): Replace NSOpenPanel-driven endpoint tester flows with a Windows file picker service.",
        "TODO(Helios): Route clipboard writes through ClipboardService instead of NSPasteboard.",
        "TODO(Helios): Route NSWorkspace-powered links and launches through ExternalLinkService.",
        "TODO(Helios): Rebuild the interactive endpoint tester incrementally once the Windows shell owns the server diagnostics flow.",
    ]

    static func repositoryRoot(startingAt currentDirectory: URL, fileManager: FileManager) -> URL {
        var cursor = currentDirectory.standardizedFileURL

        while true {
            if fileManager.fileExists(atPath: cursor.appendingPathComponent("Packages/OsaurusCore").path) {
                return cursor
            }

            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path {
                return currentDirectory.standardizedFileURL
            }
            cursor = parent
        }
    }

    static func reportsDirectory(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent("Helios/reports", isDirectory: true)
    }

    static func sharedDirectory(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent("Helios/shared", isDirectory: true)
    }

    static func ensureDirectory(_ url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    }

    static func write(_ string: String, to url: URL, fileManager: FileManager) throws {
        try ensureDirectory(url.deletingLastPathComponent(), fileManager: fileManager)
        try string.write(to: url, atomically: true, encoding: .utf8)
    }

    static func write(_ data: Data, to url: URL, fileManager: FileManager) throws {
        try ensureDirectory(url.deletingLastPathComponent(), fileManager: fileManager)
        try data.write(to: url)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func readSource(at relativePath: String, repoRoot: URL) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HeliosPorterError.sourceFileMissing(relativePath)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func firstMatches(
        pattern: String,
        in source: String,
        captureGroup: Int = 1,
        limit: Int = 3
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return []
        }

        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        var matches: [String] = []
        var seen: Set<String> = []

        regex.enumerateMatches(in: source, options: [], range: range) { result, _, stop in
            guard
                let result,
                let matchRange = Range(result.range(at: captureGroup), in: source)
            else {
                return
            }

            let value = String(source[matchRange])
            if seen.insert(value).inserted {
                matches.append(value)
            }

            if matches.count >= limit {
                stop.pointee = true
            }
        }

        return matches
    }

    static func containsAny(_ needles: [String], in source: String) -> Bool {
        needles.contains { source.contains($0) }
    }

    static func deduplicatedBridgeCapabilities(in report: PortabilityReport) -> [BridgeCapability] {
        var seen: Set<BridgeCapability> = []
        var ordered: [BridgeCapability] = []

        for capability in report.findings.flatMap(\.bridgeCapabilities) {
            if seen.insert(capability).inserted {
                ordered.append(capability)
            }
        }

        return BridgeCapability.allCases.filter { ordered.contains($0) }
    }
}
