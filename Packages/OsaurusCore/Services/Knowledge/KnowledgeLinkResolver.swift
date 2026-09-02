//
//  KnowledgeLinkResolver.swift
//  osaurus
//
//  Turns knowledge-document paths mentioned in chat text (e.g.
//  `Collection Name/Team/Report.md` inside a code span) into clickable
//  `osaurus-knowledge://` links, and resolves those links back to the
//  file on disk when clicked.
//
//  Detection is existence-gated: a span only becomes a link when it
//  resolves to a real file inside a registered collection's folder, so
//  ordinary code spans that merely look path-shaped are left alone.
//

import Foundation

@MainActor
public enum KnowledgeLinkResolver {
    /// Custom scheme carried in the `.link` attribute:
    /// `osaurus-knowledge://<collection-uuid>/<rel/path.md>`
    public static let scheme = "osaurus-knowledge"

    public struct Match {
        /// The link URL to attach.
        public let url: URL
        /// UTF-16 length of the matched prefix of the span (trailing
        /// punctuation like a sentence-ending period is excluded).
        public let matchedLength: Int
    }

    /// Span-text → resolved link (nil = known non-match). Rendering re-runs
    /// on every streaming pass; this keeps it to at most one disk stat per
    /// unique span. Cleared whenever the collection registry changes.
    private static var cache: [String: URL?] = [:]
    private static var observerInstalled = false

    private static func installObserverIfNeeded() {
        guard !observerInstalled else { return }
        observerInstalled = true
        NotificationCenter.default.addObserver(
            forName: .knowledgeCollectionsChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { cache.removeAll() }
        }
    }

    /// Trailing characters that are prose punctuation, not part of a path.
    private static let trailingPunctuation = CharacterSet(charactersIn: ".,;:!?)")

    /// If `span` names a document in a registered collection, return the
    /// link to attach. Matches `CollectionName/rel/path.ext` first, then
    /// falls back to trying the whole span as a collection-relative path.
    public static func linkURL(forCodeSpan span: String) -> Match? {
        installObserverIfNeeded()

        var candidate = span
        while let last = candidate.unicodeScalars.last, trailingPunctuation.contains(last) {
            candidate.removeLast()
        }

        // Cheap shape gate before touching the registry or disk: needs a
        // separator and a file extension in the last component.
        guard candidate.contains("/"),
            let lastComponent = candidate.split(separator: "/").last,
            lastComponent.dropFirst().contains(".")
        else { return nil }

        if let cached = cache[candidate] {
            guard let url = cached else { return nil }
            return Match(url: url, matchedLength: (candidate as NSString).length)
        }

        let collections = KnowledgeManager.shared.collections.filter(\.isEnabled)
        let resolved = resolve(candidate, in: collections)
        // Don't cache negatives before the async initial registry load has
        // populated any collections — they'd stick after load completes.
        if resolved != nil || !collections.isEmpty {
            cache[candidate] = resolved
        }
        guard let resolved else { return nil }
        return Match(url: resolved, matchedLength: (candidate as NSString).length)
    }

    private static func resolve(_ candidate: String, in collections: [KnowledgeCollection]) -> URL? {
        // Preferred form: the collection name as the leading component.
        for collection in collections where candidate.hasPrefix(collection.name + "/") {
            let relPath = String(candidate.dropFirst(collection.name.count + 1))
            if let url = linkURL(collection: collection, relPath: relPath) { return url }
        }
        // Fallback: the span is a bare collection-relative path.
        for collection in collections {
            if let url = linkURL(collection: collection, relPath: candidate) { return url }
        }
        return nil
    }

    private static func linkURL(collection: KnowledgeCollection, relPath: String) -> URL? {
        guard fileURL(collection: collection, relPath: relPath) != nil else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = collection.id.uuidString
        components.path = "/" + relPath
        return components.url
    }

    /// Resolve a clicked `osaurus-knowledge://` link back to the file on
    /// disk. Returns nil if the collection is gone or the file no longer
    /// exists (it may have been deleted since render time).
    public static func fileURL(from link: URL) -> URL? {
        guard link.scheme == scheme,
            let host = link.host, let collectionId = UUID(uuidString: host),
            let collection = KnowledgeManager.shared.collection(for: collectionId)
        else { return nil }
        let relPath = String(link.path.dropFirst())
        return fileURL(collection: collection, relPath: relPath)
    }

    /// Confinement mirrors `KnowledgeWriteService.resolvedURL` (no escapes
    /// via `..`, absolute, or tilde paths) but without the markdown-only
    /// restriction — read-side linking of a PDF or docx is fine.
    private static func fileURL(collection: KnowledgeCollection, relPath: String) -> URL? {
        guard !relPath.isEmpty, !relPath.hasPrefix("/"), !relPath.hasPrefix("~"),
            !relPath.components(separatedBy: "/").contains("..")
        else { return nil }
        let folderURL = collection.folderURL.standardizedFileURL
        let fileURL = folderURL.appendingPathComponent(relPath).standardizedFileURL
        let folderPrefix = folderURL.path.hasSuffix("/") ? folderURL.path : folderURL.path + "/"
        guard fileURL.path.hasPrefix(folderPrefix) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else { return nil }
        return fileURL
    }
}
