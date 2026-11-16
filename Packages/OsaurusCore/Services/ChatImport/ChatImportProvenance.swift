//
//  ChatImportProvenance.swift
//  osaurus
//
//  Where each imported item came from, so a re-import can say "already
//  installed" or "update available" instead of guessing from names.
//  A sidecar ledger: skills, agents, MCP servers, and commands keep their
//  own models unchanged.
//

import Foundation

struct ChatImportProvenance: Codable, Sendable, Equatable {
    var kind: String
    var name: String
    var importSource: String
    var contentHash: String
    var importedAt: Date
}

@MainActor
final class ChatImportProvenanceStore {
    static let shared = ChatImportProvenanceStore()

    private(set) var records: [ChatImportProvenance] = []
    private var loadedPath: String?

    private init() {}

    static var fileURL: URL {
        OsaurusPaths.root().appendingPathComponent("chat-imports.json")
    }

    private func loadIfNeeded() {
        let url = Self.fileURL
        guard loadedPath != url.path else { return }
        loadedPath = url.path
        guard let data = try? Data(contentsOf: url) else {
            records = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([ChatImportProvenance].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        try? FileManager.default.createDirectory(
            at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    func record(kind: ChatImportItemKind, name: String, source: String, hash: String, at date: Date = Date()) {
        loadIfNeeded()
        records.removeAll { $0.kind == kind.rawValue && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        records.append(
            ChatImportProvenance(
                kind: kind.rawValue, name: name, importSource: source, contentHash: hash, importedAt: date))
        save()
    }

    func remove(kind: ChatImportItemKind, name: String) {
        loadIfNeeded()
        let before = records.count
        records.removeAll { $0.kind == kind.rawValue && $0.name.caseInsensitiveCompare(name) == .orderedSame }
        if records.count != before { save() }
    }

    func find(kind: ChatImportItemKind, name: String) -> ChatImportProvenance? {
        loadIfNeeded()
        return records.last { $0.kind == kind.rawValue && $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
