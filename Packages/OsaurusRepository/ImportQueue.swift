//
//  ImportQueue.swift
//  osaurus
//
//  The hand-off between `osaurus import` and the app. The CLI checks a
//  bundle, copies the parts it needs into `~/.osaurus/import/pending/<id>/`
//  and writes a request. The app applies pending requests at launch (or
//  right away over loopback when it is running), writes a result, and keeps
//  receipts of what each bundle installed in `installed.json`.
//
//  Layout under `ToolsPaths.root()/import/`:
//    pending/<id>/request.json   the request
//    pending/<id>/bundle/        a copy of the referenced bundle files
//    results/<id>.json           the outcome, read by `osaurus import`
//    installed.json              receipts, one per installed item
//

import CryptoKit
import Foundation

public enum ImportAction: String, Codable, Sendable {
    case install
    case update
    case remove
}

public struct ImportOperation: Codable, Sendable, Equatable {
    public var action: ImportAction
    public var kind: BundleItemKind
    public var name: String
    /// Named by the caller rather than pulled in as an agent's dependency.
    public var explicit: Bool

    public init(action: ImportAction, kind: BundleItemKind, name: String, explicit: Bool) {
        self.action = action
        self.kind = kind
        self.name = name
        self.explicit = explicit
    }
}

public struct ImportRequest: Codable, Sendable, Equatable {
    public var id: String
    public var createdAt: Date
    public var bundleId: String
    public var bundleName: String?
    public var bundleVersion: String?
    public var operations: [ImportOperation]
    /// The caller passed `--yes` for the high-risk changes it was shown.
    public var confirmHighRisk: Bool

    public init(
        id: String = ImportQueue.newRequestId(),
        createdAt: Date = Date(),
        bundleId: String,
        bundleName: String?,
        bundleVersion: String?,
        operations: [ImportOperation],
        confirmHighRisk: Bool
    ) {
        self.id = id
        self.createdAt = createdAt
        self.bundleId = bundleId
        self.bundleName = bundleName
        self.bundleVersion = bundleVersion
        self.operations = operations
        self.confirmHighRisk = confirmHighRisk
    }
}

public enum ImportItemStatus: String, Codable, Sendable {
    case done
    case unchanged
    case needsUserAction = "needs_user_action"
    case failed
    case skipped
}

public struct ImportItemResult: Codable, Sendable, Equatable {
    public var kind: BundleItemKind
    public var name: String
    public var action: ImportAction
    public var status: ImportItemStatus
    public var message: String?
    /// Secret references that did not resolve (`keychain:SERVICE/ACCOUNT`).
    public var pendingSecrets: [String]?

    public init(
        kind: BundleItemKind,
        name: String,
        action: ImportAction,
        status: ImportItemStatus,
        message: String? = nil,
        pendingSecrets: [String]? = nil
    ) {
        self.kind = kind
        self.name = name
        self.action = action
        self.status = status
        self.message = message
        self.pendingSecrets = pendingSecrets
    }
}

public struct ImportResult: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case applied
        case partial
        case failed
    }

    public var requestId: String
    public var bundleId: String
    public var status: Status
    public var items: [ImportItemResult]
    public var finishedAt: Date

    public init(requestId: String, bundleId: String, items: [ImportItemResult], finishedAt: Date = Date()) {
        self.requestId = requestId
        self.bundleId = bundleId
        self.items = items
        self.finishedAt = finishedAt
        let failed = items.contains { $0.status == .failed }
        let ok = items.contains { $0.status == .done || $0.status == .unchanged }
        let pending = items.contains { $0.status == .needsUserAction }
        if failed {
            status = ok || pending ? .partial : .failed
        } else if pending {
            status = .partial
        } else {
            status = .applied
        }
    }

    /// 0 applied, 1 something failed, 3 applied but the user must finish
    /// something (a missing secret, a model to download).
    public var exitCode: Int32 {
        if items.contains(where: { $0.status == .failed }) { return 1 }
        if items.contains(where: { $0.status == .needsUserAction }) { return 3 }
        return 0
    }
}

/// What one bundle installed, so later updates and removes only touch
/// items the bundle owns.
public struct ImportReceipt: Codable, Sendable, Equatable {
    public var bundleId: String
    public var bundleName: String?
    public var bundleVersion: String?
    public var kind: BundleItemKind
    public var name: String
    public var explicit: Bool
    public var contentHash: String
    public var installedAt: Date
    public var updatedAt: Date
    public var agentId: String?
    public var skillDirectory: String?
    public var mcpProviderId: String?
    public var harnessRuntimeId: String?
    /// Secret references that did not resolve when the item was applied.
    public var pendingSecrets: [String]?
    /// The last apply left something for the user to finish, so `update`
    /// applies the item again even when its content has not changed.
    public var needsUserAction: Bool?
    /// For agents: the bundle skills, MCP servers and harness runtime it
    /// was installed with.
    public var skills: [String]?
    public var mcpServers: [String]?
    public var harnessRuntime: String?

    public init(
        bundleId: String,
        bundleName: String?,
        bundleVersion: String?,
        kind: BundleItemKind,
        name: String,
        explicit: Bool,
        contentHash: String,
        installedAt: Date = Date(),
        updatedAt: Date = Date(),
        agentId: String? = nil,
        skillDirectory: String? = nil,
        mcpProviderId: String? = nil,
        pendingSecrets: [String]? = nil,
        needsUserAction: Bool? = nil,
        skills: [String]? = nil,
        mcpServers: [String]? = nil,
        harnessRuntimeId: String? = nil,
        harnessRuntime: String? = nil
    ) {
        self.bundleId = bundleId
        self.bundleName = bundleName
        self.bundleVersion = bundleVersion
        self.kind = kind
        self.name = name
        self.explicit = explicit
        self.contentHash = contentHash
        self.installedAt = installedAt
        self.updatedAt = updatedAt
        self.agentId = agentId
        self.skillDirectory = skillDirectory
        self.mcpProviderId = mcpProviderId
        self.pendingSecrets = pendingSecrets
        self.needsUserAction = needsUserAction
        self.skills = skills
        self.mcpServers = mcpServers
        self.harnessRuntimeId = harnessRuntimeId
        self.harnessRuntime = harnessRuntime
    }

    public func matches(kind: BundleItemKind, name: String) -> Bool {
        guard self.kind == kind else { return false }
        if kind == .skill { return OsaurusBundle.skillSlug(for: self.name) == OsaurusBundle.skillSlug(for: name) }
        return self.name.caseInsensitiveCompare(name) == .orderedSame
    }
}

public struct PendingImport: Sendable {
    public var request: ImportRequest
    public var directory: URL
    public var bundleDirectory: URL { directory.appendingPathComponent("bundle", isDirectory: true) }
}

public enum ImportQueue {
    public static func root() -> URL { ToolsPaths.root().appendingPathComponent("import", isDirectory: true) }
    public static func pendingRoot() -> URL { root().appendingPathComponent("pending", isDirectory: true) }
    public static func resultsRoot() -> URL { root().appendingPathComponent("results", isDirectory: true) }
    public static func receiptsURL() -> URL { root().appendingPathComponent("installed.json") }
    public static func resultURL(id: String) -> URL { resultsRoot().appendingPathComponent("\(id).json") }

    /// Sortable and unique: `20261022-143005-1a2b3c4d`.
    public static func newRequestId(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return "\(formatter.string(from: now))-\(suffix)"
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    // MARK: Enqueue

    /// Writes a request. When `bundle` is set, copies the manifest and every
    /// file it lists (not the installer's other files), so the copy loads as
    /// a bundle on its own. The request appears atomically: it is staged
    /// under a dot name and renamed into place.
    @discardableResult
    public static func enqueue(_ request: ImportRequest, bundle: OsaurusBundle?) throws -> URL {
        let fm = FileManager.default
        try ensurePrivateDirectory(pendingRoot())
        let staging = pendingRoot().appendingPathComponent(".staging-\(request.id)", isDirectory: true)
        let final = pendingRoot().appendingPathComponent(request.id, isDirectory: true)
        try? fm.removeItem(at: staging)
        try ensurePrivateDirectory(staging)
        do {
            if let bundle {
                let target = staging.appendingPathComponent("bundle", isDirectory: true)
                try ensurePrivateDirectory(target)
                try copy(bundle.manifestURL, to: target.appendingPathComponent(OsaurusBundleFormat.manifestFileName))
                for skill in bundle.skills {
                    try copy(skill.directory, to: target.appendingPathComponent(skill.path))
                }
                for agent in bundle.agents {
                    try copy(agent.file, to: target.appendingPathComponent(agent.path))
                }
            }
            try encoder().encode(request).write(to: staging.appendingPathComponent("request.json"), options: .atomic)
            try fm.moveItem(at: staging, to: final)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        return final
    }

    private static func copy(_ source: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { return }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: destination)
    }

    // MARK: Read / complete

    /// Pending requests, oldest first. Unreadable entries are skipped.
    public static func pending() -> [PendingImport] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: pendingRoot(), includingPropertiesForKeys: nil) else {
            return []
        }
        return entries.compactMap { dir -> PendingImport? in
            guard !dir.lastPathComponent.hasPrefix(".") else { return nil }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("request.json")),
                let request = try? decoder().decode(ImportRequest.self, from: data)
            else { return nil }
            return PendingImport(request: request, directory: dir)
        }.sorted { ($0.request.createdAt, $0.request.id) < ($1.request.createdAt, $1.request.id) }
    }

    public static func pending(id: String) -> PendingImport? {
        pending().first { $0.request.id == id }
    }

    /// Saves the result and drops the pending request.
    public static func complete(_ pending: PendingImport, result: ImportResult) throws {
        try ensurePrivateDirectory(resultsRoot())
        try encoder().encode(result).write(to: resultURL(id: result.requestId), options: .atomic)
        try? FileManager.default.removeItem(at: pending.directory)
    }

    public static func result(id: String) -> ImportResult? {
        guard let data = try? Data(contentsOf: resultURL(id: id)) else { return nil }
        return try? decoder().decode(ImportResult.self, from: data)
    }

    /// Drops pending requests for a bundle; returns their ids.
    @discardableResult
    public static func cancelPending(bundleId: String) -> [String] {
        pending().filter { $0.request.bundleId == bundleId }.map { item in
            try? FileManager.default.removeItem(at: item.directory)
            return item.request.id
        }
    }

    // MARK: Receipts

    private struct ReceiptFile: Codable {
        var version: Int
        var receipts: [ImportReceipt]
    }

    public static func loadReceipts() -> [ImportReceipt] {
        guard let data = try? Data(contentsOf: receiptsURL()),
            let file = try? decoder().decode(ReceiptFile.self, from: data)
        else { return [] }
        return file.receipts
    }

    public static func saveReceipts(_ receipts: [ImportReceipt]) throws {
        try ensurePrivateDirectory(root())
        let sorted = receipts.sorted {
            ($0.bundleId, $0.kind.rawValue, $0.name.lowercased()) < ($1.bundleId, $1.kind.rawValue, $1.name.lowercased())
        }
        try encoder().encode(ReceiptFile(version: 1, receipts: sorted)).write(to: receiptsURL(), options: .atomic)
    }
}

// MARK: - Content hashes

extension OsaurusBundle {
    /// A stable hash of what an item would install, so re-running the same
    /// bundle version reports `unchanged` instead of rewriting.
    public func contentHash(kind: BundleItemKind, name: String) -> String? {
        var hasher = SHA256()
        switch kind {
        case .skill:
            guard let skill = skill(named: name) else { return nil }
            let fm = FileManager.default
            guard let enumerator = fm.enumerator(at: skill.directory, includingPropertiesForKeys: [.isRegularFileKey])
            else { return nil }
            let base = skill.directory.standardizedFileURL.pathComponents.count
            var files: [(String, URL)] = []
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let relative = url.standardizedFileURL.pathComponents.dropFirst(base).joined(separator: "/")
                files.append((relative, url))
            }
            for (relative, url) in files.sorted(by: { $0.0 < $1.0 }) {
                hasher.update(data: Data(relative.utf8))
                hasher.update(data: Data([0]))
                hasher.update(data: (try? Data(contentsOf: url)) ?? Data())
                hasher.update(data: Data([0]))
            }
        case .agent:
            guard let agent = agent(named: name), let data = try? Data(contentsOf: agent.file) else { return nil }
            hasher.update(data: data)
        case .mcp:
            guard let raw = try? rawMCPServerEntries()[name.lowercased()],
                let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
            else { return nil }
            hasher.update(data: data)
        case .harnessRuntime:
            guard let raw = try? rawHarnessRuntimeEntries()[name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()],
                let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
            else { return nil }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
