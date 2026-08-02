//
//  OsaurusGuide.swift
//  osaurus
//
//  Loader for the bundled Osaurus user guide — the curated, user-facing
//  topic corpus under `Resources/Guide/guide-*.md` that backs the
//  `osaurus_help` read tool. Each topic file carries a small front-matter
//  block (`title`, `summary`, `order`) followed by the markdown body.
//
//  Topics are parsed once and cached: the corpus ships inside the app
//  bundle and cannot change at runtime, so the index and bodies are
//  byte-stable for the whole session (KV-cache friendly for repeated
//  `topics` calls).
//

import Foundation

/// One parsed guide topic.
public struct OsaurusGuideTopic: Sendable, Equatable {
    /// Stable kebab-case id derived from the filename
    /// (`guide-local-models.md` → `local-models`).
    public let id: String
    /// Human-readable title from front matter.
    public let title: String
    /// One-line summary shown in the topic index.
    public let summary: String
    /// Index ordering (lower first); ties break alphabetically by id.
    public let order: Int
    /// Full markdown body (front matter stripped).
    public let body: String
}

public enum OsaurusGuide {
    /// Filename prefix for every topic resource. The prefix keeps the
    /// flat-bundle fallback enumeration unambiguous: SwiftPM `.process`
    /// resources may or may not preserve the `Guide/` subdirectory
    /// depending on toolchain, so lookups try `subdirectory: "Guide"`
    /// first and fall back to prefix-filtered root enumeration.
    static let resourcePrefix = "guide-"

    /// All topics sorted by (`order`, `id`). Parsed once per process.
    public static var topics: [OsaurusGuideTopic] { cached }

    /// Look up one topic by id (case-insensitive, tolerant of a stray
    /// `guide-` prefix so `guide-local-models` also resolves).
    public static func topic(id: String) -> OsaurusGuideTopic? {
        let normalized = normalizeTopicId(id)
        return cached.first { $0.id == normalized }
    }

    /// Lowercase, trim, and strip an optional `guide-` prefix.
    static func normalizeTopicId(_ raw: String) -> String {
        var id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if id.hasPrefix(resourcePrefix) {
            id = String(id.dropFirst(resourcePrefix.count))
        }
        if id.hasSuffix(".md") {
            id = String(id.dropLast(3))
        }
        return id
    }

    // MARK: - Parsing

    /// Parse one topic file's contents. Internal for unit tests.
    /// Returns nil when the front-matter block is missing or lacks a
    /// title — a malformed topic is dropped rather than surfaced broken.
    static func parseTopic(id: String, contents: String) -> OsaurusGuideTopic? {
        let normalizedNewlines = contents.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalizedNewlines.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()
        guard let closeIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }

        var title = ""
        var summary = ""
        var order = Int.max
        for line in lines[..<closeIndex] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "title": title = value
            case "summary": summary = value
            case "order": order = Int(value) ?? Int.max
            default: break
            }
        }
        guard !title.isEmpty else { return nil }

        let body = lines[lines.index(after: closeIndex)...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return OsaurusGuideTopic(id: id, title: title, summary: summary, order: order, body: body)
    }

    // MARK: - Bundle loading

    private static let cached: [OsaurusGuideTopic] = loadAll()

    private static func loadAll() -> [OsaurusGuideTopic] {
        var byId: [String: OsaurusGuideTopic] = [:]
        for url in topicResourceURLs() {
            let filename = url.deletingPathExtension().lastPathComponent
            guard filename.hasPrefix(resourcePrefix) else { continue }
            let id = normalizeTopicId(filename)
            guard byId[id] == nil else { continue }
            guard let contents = try? String(contentsOf: url, encoding: .utf8),
                let topic = parseTopic(id: id, contents: contents)
            else {
                assertionFailure("Malformed guide topic resource: \(url.lastPathComponent)")
                continue
            }
            byId[id] = topic
        }
        return byId.values.sorted {
            ($0.order, $0.id) < ($1.order, $1.id)
        }
    }

    private static func topicResourceURLs() -> [URL] {
        var urls: [URL] = []
        if let inSubdirectory = Bundle.module.urls(
            forResourcesWithExtension: "md",
            subdirectory: "Guide"
        ) {
            urls.append(contentsOf: inSubdirectory)
        }
        // Flat fallback for toolchains that flatten processed resources.
        if let flat = Bundle.module.urls(forResourcesWithExtension: "md", subdirectory: nil) {
            urls.append(contentsOf: flat.filter { $0.lastPathComponent.hasPrefix(resourcePrefix) })
        }
        return urls
    }
}
