//
//  ChatImportEvalHarness.swift
//  osaurus
//
//  Runs the import reader and verifier over fixture documents for the
//  OsaurusEvals `chat_import_reader` domain. No network and no install:
//  the fixtures stand in for downloaded pages, and each expected item is
//  scored found (a row with that kind and name), grounded (it survived the
//  verifier), and the right kind.
//

import Foundation

public enum ChatImportEvalHarness {
    public struct Document: Sendable {
        public var origin: String
        public var path: String?
        public var text: String

        public init(origin: String, path: String? = nil, text: String) {
            self.origin = origin
            self.path = path
            self.text = text
        }
    }

    public struct Expected: Sendable {
        /// `skill`, `agent`, `mcp_server`, `command`, `plugin`, or `manual_step`.
        public var kind: String
        /// Case-insensitive substring of the row name.
        public var name: String

        public init(kind: String, name: String) {
            self.kind = kind
            self.name = name
        }
    }

    public struct Outcome: Sendable {
        public var found: Int
        public var expected: Int
        public var forbiddenHits: [String]
        public var checks: [String]
        public var readerRan: Bool
        public var readerModel: String?
        public var tokensPerSecond: Double?
        public var completionTokens: Int
        public var readerFailure: String?

        public var passed: Bool { found == expected && forbiddenHits.isEmpty }
    }

    /// `forbidden` lists values (URLs, commands, names) that must not appear
    /// in any row: an injected server, an invented value.
    public static func run(
        documents: [Document], userText: String, expected: [Expected], forbidden: [String], model: String?
    ) async -> Outcome {
        var bundle = ChatImportBundle(userText: userText)
        for (index, doc) in documents.enumerated() {
            bundle.documents.append(
                ChatImportDocument(id: "d\(index + 1)", origin: doc.origin, path: doc.path, text: doc.text))
        }
        let fast = ChatImportFastPaths.run(bundle)
        var items = fast.items
        let unread = bundle.documents.filter { !fast.consumedDocumentIds.contains($0.id) }
        var reader: ChatImportReader.Outcome?
        if ChatImportPipeline.shouldRead(unread, fastItems: fast.items) {
            let outcome = await ChatImportReader.read(documents: unread, modelName: model)
            reader = outcome
            if let manifest = outcome.manifest {
                items += ChatImportVerifier.verify(
                    manifest: manifest, bundle: bundle, fastPathItems: fast.items,
                    consumedDocumentIds: fast.consumedDocumentIds
                ).items
            } else if items.filter(\.isActionable).isEmpty, let page = ChatImportVerifier.pageAsSkill(bundle) {
                items.append(page)
            }
        }
        _ = ChatImportVerifier.cleanSavedText(&items)

        var checks: [String] = []
        var found = 0
        for want in expected {
            let wanted = want.name.lowercased()
            let named = items.filter { wanted.isEmpty || $0.name.lowercased().contains(wanted) }
            let hit = named.contains { $0.kind.rawValue == want.kind }
            if hit { found += 1 }
            let detail =
                hit ? "" : named.isEmpty ? " (no row)" : " (found as \(named.map(\.kind.rawValue).joined(separator: "/")))"
            checks.append((hit ? "PASS " : "FAIL ") + "\(want.kind) \"\(want.name)\"" + detail)
        }
        var hits: [String] = []
        for value in forbidden {
            let lower = value.lowercased()
            let leaked = items.contains { item in
                item.name.lowercased().contains(lower) || item.detail.lowercased().contains(lower)
                    || String(describing: item.payload).lowercased().contains(lower)
            }
            if leaked { hits.append(value) }
            checks.append((leaked ? "FAIL " : "PASS ") + "no row carries \"\(value)\"")
        }
        checks.append("INFO rows: " + items.map { "\($0.kind.rawValue):\($0.name)" }.joined(separator: ", "))
        return Outcome(
            found: found, expected: expected.count, forbiddenHits: hits, checks: checks, readerRan: reader != nil,
            readerModel: reader?.modelName, tokensPerSecond: reader?.tokensPerSecond,
            completionTokens: reader?.completionTokens ?? 0, readerFailure: reader?.failure)
    }
}
