//
//  TemplateStore.swift
//  osaurus
//
//  The template library for both kinds, versioned on disk:
//
//    ~/.osaurus/template-library/<template-uuid>/v<N>.json
//    ~/.osaurus/template-library/index.json   (per-Mac preferences)
//
//  Every save writes a new immutable version file; nothing ever rewrites
//  an existing one. Restoring an old version saves it again as the newest.
//  Per-Mac preferences that are not part of the template (Orchestrator
//  visibility) live in the index so toggling them never mints a version.
//
//  Built-in templates ship in the app bundle (`Resources/Templates/
//  *-template-*.json`) with fixed ids. A library version of the same id
//  shadows the built-in.
//

import Combine
import Foundation

@MainActor
public final class TemplateStore: ObservableObject {
    public static let shared = TemplateStore()

    /// Latest version of every library template, sorted by name.
    @Published public private(set) var templates: [Template] = []

    public let builtIn: [Template] = TemplateStore.loadBuiltIn()

    public nonisolated static let maxFileBytes = 2 * 1024 * 1024

    public enum StoreError: Error, LocalizedError, Equatable {
        case notFound(String)
        case tooLarge
        case write(String)
        case builtInReadOnly
        /// A signed template whose content or address no longer matches
        /// its signature. Never stored, never resealed.
        case signatureMismatch
        /// A version already here is signed by `localAddress`; the incoming
        /// one is not validly signed by it. Only a copy under a new id can
        /// be kept.
        case signerMismatch(localAddress: String)
        /// Same id and version with different content, and no choice made.
        case conflictNeedsResolution

        public var errorDescription: String? {
            switch self {
            case .notFound(let what): return L("No template \(what).")
            case .tooLarge: return L("Template file is too large.")
            case .write(let detail): return L("Could not save template: \(detail)")
            case .builtInReadOnly: return L("Built-in templates cannot be changed. Save a copy to your library first.")
            case .signatureMismatch:
                return L("The template's signature does not match its content. The file was changed after it was signed, so it was not imported.")
            case .signerMismatch(let address):
                return L("Your copy of this template is signed by \(SharedAgentIdentity.shortAddress(address)) and this file is not. Import it as a copy under a new name instead.")
            case .conflictNeedsResolution:
                return L("This version is already here with different content. Choose Keep both or Replace.")
            }
        }
    }

    private struct Index: Codable {
        var version: Int = 1
        var hiddenFromOrchestrator: [UUID] = []
    }

    private var index = Index()

    private init() {
        reload()
    }

    // MARK: - Paths

    public nonisolated static var directory: URL { OsaurusPaths.templateLibrary() }

    nonisolated static func templateDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    nonisolated static func versionURL(_ id: UUID, version: Int) -> URL {
        templateDirectory(id).appendingPathComponent("v\(version).json")
    }

    nonisolated static var indexURL: URL { directory.appendingPathComponent("index.json") }

    // MARK: - Reading

    public func reload() {
        index = Self.readIndex()
        templates = Self.loadLatest().map(applyingIndex)
    }

    private func applyingIndex(_ t: Template) -> Template {
        var copy = t
        if index.hiddenFromOrchestrator.contains(t.id) { copy.availableToOrchestrator = false }
        return copy
    }

    private nonisolated static func readIndex() -> Index {
        guard let data = try? Data(contentsOf: indexURL),
            let idx = try? JSONDecoder().decode(Index.self, from: data)
        else { return Index() }
        return idx
    }

    private func writeIndex() {
        OsaurusPaths.ensureExistsSilent(Self.directory)
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: Self.indexURL, options: .atomic)
    }

    /// Version numbers present for one template, ascending.
    nonisolated static func versionNumbers(_ id: UUID) -> [Int] {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: templateDirectory(id), includingPropertiesForKeys: nil)
        else { return [] }
        return files.compactMap { url -> Int? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", name.hasPrefix("v") else { return nil }
            return Int(name.dropFirst())
        }.sorted()
    }

    nonisolated static func load(_ id: UUID, version: Int) throws -> Template {
        let url = versionURL(id, version: version)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notFound("\(id.uuidString) v\(version)")
        }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
            size > maxFileBytes
        {
            throw StoreError.tooLarge
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try Template.parse(text)
    }

    nonisolated static func loadLatest() -> [Template] {
        guard
            let dirs = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        var out: [Template] = []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            for v in versionNumbers(id).reversed() {
                if let t = try? load(id, version: v) {
                    out.append(t)
                    break
                }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Built-ins not shadowed by the library, then the library.
    public var allTemplates: [Template] {
        let userIDs = Set(templates.map(\.id))
        return (builtIn.filter { !userIDs.contains($0.id) }.map(applyingIndex) + templates)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func allTemplates(kind: TemplateKind) -> [Template] {
        allTemplates.filter { $0.kind == kind }
    }

    public func isBuiltIn(_ template: Template) -> Bool {
        !templates.contains { $0.id == template.id } && builtIn.contains { $0.id == template.id }
    }

    /// Latest version of a template, library first.
    public func latest(id: UUID) -> Template? {
        templates.first { $0.id == id } ?? builtIn.first { $0.id == id }.map(applyingIndex)
    }

    /// A specific version, from the library or the matching built-in.
    public func template(id: UUID, version: Int) -> Template? {
        if let t = try? Self.load(id, version: version) { return applyingIndex(t) }
        if let b = builtIn.first(where: { $0.id == id && $0.version == version }) { return applyingIndex(b) }
        return nil
    }

    /// Every stored version, newest first. A built-in counts as its own
    /// version when the library has not stored that number.
    public func versions(of id: UUID) -> [Template] {
        var out = Self.versionNumbers(id).reversed().compactMap { try? Self.load(id, version: $0) }
        if let b = builtIn.first(where: { $0.id == id }), !out.contains(where: { $0.version == b.version }) {
            out.append(b)
            out.sort { $0.version > $1.version }
        }
        return out
    }

    /// Case-insensitive lookup by display name or slug, for the orchestrator.
    public func template(named raw: String, kind: TemplateKind? = nil) -> Template? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        if let id = UUID(uuidString: key), let t = latest(id: id), kind == nil || t.kind == kind {
            return t
        }
        let slug = Template.slug(for: key)
        return allTemplates.first {
            (kind == nil || $0.kind == kind)
                && ($0.name.caseInsensitiveCompare(key) == .orderedSame || $0.slug == slug)
        }
    }

    public func orchestratorVisible(kind: TemplateKind? = nil) -> [Template] {
        allTemplates.filter { $0.availableToOrchestrator && (kind == nil || $0.kind == kind) }
    }

    public var orchestratorVisible: [Template] { orchestratorVisible(kind: nil) }

    public func exists(named name: String) -> Bool { template(named: name) != nil }

    public var takenSlugs: Set<String> { Set(allTemplates.map(\.slug)) }

    /// Bundled templates. A malformed resource is a packaging error.
    private nonisolated static func loadBuiltIn() -> [Template] {
        var urls: [URL] = []
        if let nested = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Templates") {
            urls.append(contentsOf: nested)
        }
        if let flat = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) {
            urls.append(contentsOf: flat.filter { $0.lastPathComponent.contains("-template-") })
        }
        var seen = Set<String>()
        var out: [Template] = []
        for url in urls where url.lastPathComponent.contains("-template-") {
            guard seen.insert(url.lastPathComponent).inserted else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                let template = try? Template.parse(text)
            else {
                assertionFailure("Bundled template failed to parse: \(url.lastPathComponent)")
                continue
            }
            out.append(template)
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Writing

    /// Saves `template` as the next version of its id (version 1 when new).
    /// The template is sealed: requirements re-derived, hash recomputed.
    @discardableResult
    public func save(_ template: Template, changelog: String? = nil) throws -> Template {
        let existing = Self.versionNumbers(template.id).last
            ?? builtIn.first(where: { $0.id == template.id })?.version
        var copy = template
        copy.version = (existing ?? 0) + 1
        if let changelog { copy.changelog = changelog }
        copy.createdAt = Date()
        return try write(copy.sealed())
    }

    /// Writes one exact version (import). Refuses to overwrite: versions
    /// are immutable. An unsigned template with a stale hash is resealed;
    /// a signed one is stored exactly as signed or refused, never resealed
    /// (that would turn a tampered file into an unsigned-looking one).
    @discardableResult
    public func store(exactVersion template: Template) throws -> Template {
        let url = Self.versionURL(template.id, version: template.version)
        guard !FileManager.default.fileExists(atPath: url.path) else { return template }
        var copy = template
        if copy.author?.isSigned == true {
            guard TemplateSigner.status(of: copy).isValidSignature else { throw StoreError.signatureMismatch }
        } else if copy.contentHash.isEmpty || !copy.hashIsValid {
            copy = copy.sealed()
        }
        return try write(copy)
    }

    private func write(_ template: Template) throws -> Template {
        let url = Self.versionURL(template.id, version: template.version)
        do {
            try OsaurusPaths.ensureExists(Self.templateDirectory(template.id))
            let json = try template.jsonString()
            guard json.utf8.count <= Self.maxFileBytes else { throw StoreError.tooLarge }
            try Data(json.utf8).write(to: url, options: .atomic)
        } catch let e as StoreError {
            throw e
        } catch {
            throw StoreError.write(error.localizedDescription)
        }
        if template.availableToOrchestrator {
            index.hiddenFromOrchestrator.removeAll { $0 == template.id }
        } else if !index.hiddenFromOrchestrator.contains(template.id) {
            index.hiddenFromOrchestrator.append(template.id)
        }
        writeIndex()
        reload()
        return template
    }

    /// Re-saves an old version as the newest. History is never rewritten.
    @discardableResult
    public func restore(id: UUID, version: Int) throws -> Template {
        guard let old = template(id: id, version: version) else {
            throw StoreError.notFound("\(id.uuidString) v\(version)")
        }
        return try save(old, changelog: L("Restored version \(version)"))
    }

    /// Renaming is a content change, so it is a new version.
    @discardableResult
    public func rename(id: UUID, to newName: String) throws -> Template {
        guard let t = latest(id: id) else { throw StoreError.notFound(id.uuidString) }
        return try save(t.renamed(to: newName), changelog: L("Renamed to \(newName)"))
    }

    public func setAvailableToOrchestrator(_ visible: Bool, id: UUID) {
        index.hiddenFromOrchestrator.removeAll { $0 == id }
        if !visible { index.hiddenFromOrchestrator.append(id) }
        writeIndex()
        reload()
        objectWillChange.send()
    }

    /// Deletes every stored version. Built-ins cannot be deleted; a
    /// shadowing library copy can, which brings the built-in back.
    public func delete(id: UUID) throws {
        let dir = Self.templateDirectory(id)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            if builtIn.contains(where: { $0.id == id }) { throw StoreError.builtInReadOnly }
            throw StoreError.notFound(id.uuidString)
        }
        try FileManager.default.removeItem(at: dir)
        index.hiddenFromOrchestrator.removeAll { $0 == id }
        writeIndex()
        reload()
    }

    // MARK: - Import identity

    public enum ImportDisposition: Equatable, Sendable {
        /// Unknown id.
        case new
        /// The same id, version, and content are already here.
        case alreadyPresent
        /// A higher version of a known id.
        case update(fromVersion: Int)
        /// An older version than the newest one here; stored for history only.
        case older(localLatest: Int)
        /// Same id and version, different content: keep both or replace.
        case conflict
        /// A version here is signed by `localAddress` and the incoming one
        /// is not validly signed by it. Only keep-both (a copy under a new
        /// id) applies.
        case signerMismatch(localAddress: String)
    }

    public func disposition(for incoming: Template) -> ImportDisposition {
        let local = versions(of: incoming.id)
        guard let latest = local.first else { return .new }
        if let same = local.first(where: { $0.version == incoming.version }),
            same.contentHash == incoming.contentHash
        {
            return .alreadyPresent
        }
        if let address = TemplateSigner.continuityBreak(
            from: local, to: incoming, knownAgent: { AgentIdentityRegistry.shared.agentId(forAddress: $0) })
        {
            return .signerMismatch(localAddress: address)
        }
        if local.contains(where: { $0.version == incoming.version }) { return .conflict }
        if incoming.version > latest.version { return .update(fromVersion: latest.version) }
        return .older(localLatest: latest.version)
    }

    /// Applies an import according to the user's conflict choice.
    public enum ConflictResolution: Sendable {
        case keepBoth(name: String)
        case replace
    }

    /// Imports `incoming`. A conflict needs an explicit `resolution`; a
    /// signer mismatch accepts only `.keepBoth`. A signed template whose
    /// signature does not verify is refused.
    @discardableResult
    public func importTemplate(_ incoming: Template, resolution: ConflictResolution? = nil) throws -> Template {
        let sanitized = TemplateExportSanitizer.sanitized(incoming)
        if sanitized.author?.isSigned == true, !TemplateSigner.status(of: sanitized).isValidSignature {
            throw StoreError.signatureMismatch
        }
        switch disposition(for: sanitized) {
        case .new, .update, .older:
            return try store(exactVersion: sanitized)
        case .alreadyPresent:
            return latest(id: sanitized.id) ?? sanitized
        case .conflict:
            switch resolution {
            case .keepBoth(let name)?:
                return try save(sanitized.forked(named: name), changelog: L("Imported copy"))
            case .replace?:
                return try save(sanitized, changelog: L("Replaced from import of v\(sanitized.version)"))
            case nil:
                throw StoreError.conflictNeedsResolution
            }
        case .signerMismatch(let address):
            guard case .keepBoth(let name)? = resolution else { throw StoreError.signerMismatch(localAddress: address) }
            return try save(sanitized.forked(named: name), changelog: L("Imported copy"))
        }
    }

    /// Test seam.
    func resetForTesting() {
        try? FileManager.default.removeItem(at: Self.directory)
        index = Index()
        templates = []
    }
}
