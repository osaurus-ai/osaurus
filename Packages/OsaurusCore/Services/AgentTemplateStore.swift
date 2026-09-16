//
//  AgentTemplateStore.swift
//  osaurus
//
//  The agent template library on disk: `~/.osaurus/templates/<slug>.json`.
//  It shares the directory with `osaurus_config`'s named YAML templates so
//  the orchestrator's `templates` action and the Templates tab read one
//  set. JSON files whose `format` is `osaurus.agent-template` are agent
//  templates; everything else in the directory is left alone.
//
//  Path confinement mirrors `ConfigTemplateStore`: slugs come from a strict
//  character set and the resolved URL (symlinks followed) must stay inside
//  the directory.
//

import Combine
import Foundation

@MainActor
public final class AgentTemplateStore: ObservableObject {
    public static let shared = AgentTemplateStore()

    /// User library contents, sorted by name. Reloaded on demand and after writes.
    @Published public private(set) var templates: [AgentTemplate] = []

    /// Templates shipped inside the app bundle (`Resources/Templates/
    /// agent-template-*.json`). Read-only: they can be used, copied, and
    /// saved into the library, never renamed or deleted. A library template
    /// with the same slug shadows the built-in one.
    public let builtIn: [AgentTemplate] = AgentTemplateStore.loadBuiltIn()

    /// Built-ins not shadowed by a library entry, followed by the library.
    public var allTemplates: [AgentTemplate] {
        let userSlugs = Set(templates.map(\.id))
        return builtIn.filter { !userSlugs.contains($0.id) } + templates
    }

    public func isBuiltIn(_ template: AgentTemplate) -> Bool {
        !templates.contains { $0.id == template.id } && builtIn.contains { $0.id == template.id }
    }

    public nonisolated static let fileExtension = "json"
    /// Same ceiling as `osaurus_config` documents.
    public nonisolated static let maxFileBytes = 512 * 1024

    public enum StoreError: Error, LocalizedError, Equatable {
        case badSlug
        case notFound(String)
        case tooLarge
        case write(String)

        public var errorDescription: String? {
            switch self {
            case .badSlug: return "Template name resolves outside the templates directory."
            case .notFound(let slug): return "No template named `\(slug)`."
            case .tooLarge: return "Template file is too large."
            case .write(let detail): return "Could not save template: \(detail)"
            }
        }
    }

    private init() {
        reload()
    }

    // MARK: - Paths

    public nonisolated static var directory: URL { OsaurusPaths.configTemplates() }

    /// Resolve a slug to a URL confined to the templates directory.
    nonisolated static func confinedURL(slug: String) -> URL? {
        guard slug == AgentTemplate.slug(for: slug), !slug.isEmpty else { return nil }
        let dir = directory.resolvingSymlinksInPath().standardizedFileURL
        let url = dir.appendingPathComponent("\(slug).\(fileExtension)")
            .resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(dir.path + "/") else { return nil }
        return url
    }

    // MARK: - Reading

    public func reload() {
        templates = Self.loadAll()
    }

    /// All agent templates on disk. Non-template JSON and YAML files in the
    /// directory are skipped silently.
    public nonisolated static func loadAll() -> [AgentTemplate] {
        let dir = directory
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return [] }
        var out: [AgentTemplate] = []
        for url in entries where url.pathExtension.lowercased() == fileExtension {
            let slug = url.deletingPathExtension().lastPathComponent
            guard let confined = confinedURL(slug: slug), confined.path == url.resolvingSymlinksInPath().standardizedFileURL.path
            else { continue }
            if let template = try? load(slug: slug) {
                out.append(template)
            }
        }
        return out.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public nonisolated static func load(slug: String) throws -> AgentTemplate {
        guard let url = confinedURL(slug: slug) else { throw StoreError.badSlug }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notFound(slug)
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attrs?[.size] as? Int, size > maxFileBytes {
            throw StoreError.tooLarge
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return try AgentTemplate.parse(text)
    }

    /// Case-insensitive lookup by display name or slug across the library
    /// and the built-ins, for the orchestrator ("use the Cloud Agent template").
    public func template(named raw: String) -> AgentTemplate? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let slug = AgentTemplate.slug(for: key)
        return allTemplates.first {
            $0.name.caseInsensitiveCompare(key) == .orderedSame || $0.id == slug
        }
    }

    /// Templates the orchestrator may see (library and built-in).
    public var orchestratorVisible: [AgentTemplate] {
        allTemplates.filter(\.availableToOrchestrator)
    }

    /// Bundled templates. A malformed resource is a packaging error and is
    /// skipped rather than crashing the store.
    private nonisolated static func loadBuiltIn() -> [AgentTemplate] {
        let prefix = "agent-template-"
        var urls: [URL] = []
        if let nested = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Templates") {
            urls.append(contentsOf: nested)
        }
        // Flat fallback for toolchains that flatten processed resources.
        if let flat = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil) {
            urls.append(contentsOf: flat.filter { $0.lastPathComponent.hasPrefix(prefix) })
        }
        var seen = Set<String>()
        var out: [AgentTemplate] = []
        for url in urls where url.lastPathComponent.hasPrefix(prefix) {
            guard seen.insert(url.lastPathComponent).inserted else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                let template = try? AgentTemplate.parse(text)
            else {
                assertionFailure("Bundled agent template failed to parse: \(url.lastPathComponent)")
                continue
            }
            out.append(template)
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func exists(named name: String) -> Bool {
        template(named: name) != nil
    }

    // MARK: - Writing

    /// Writes the template under its slug. An existing file with the same
    /// slug is replaced (callers confirm overwrite in the UI first).
    @discardableResult
    public func save(_ template: AgentTemplate) throws -> URL {
        guard let url = Self.confinedURL(slug: template.id) else { throw StoreError.badSlug }
        do {
            try OsaurusPaths.ensureExists(Self.directory)
            let json = try template.jsonString()
            try Data(json.utf8).write(to: url, options: .atomic)
        } catch {
            throw StoreError.write(error.localizedDescription)
        }
        reload()
        return url
    }

    /// Flip orchestrator visibility in place.
    public func setAvailableToOrchestrator(_ visible: Bool, slug: String) throws {
        guard var template = templates.first(where: { $0.id == slug }) else {
            throw StoreError.notFound(slug)
        }
        template.availableToOrchestrator = visible
        try save(template)
    }

    /// Renames by re-slugging: the old file is removed after the new one
    /// is written so a failed write never loses the template.
    public func rename(slug: String, to newName: String) throws {
        guard var template = templates.first(where: { $0.id == slug }) else {
            throw StoreError.notFound(slug)
        }
        template.name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newSlug = template.id
        try save(template)
        if newSlug != slug, let old = Self.confinedURL(slug: slug) {
            try? FileManager.default.removeItem(at: old)
            reload()
        }
    }

    public func delete(slug: String) throws {
        guard let url = Self.confinedURL(slug: slug) else { throw StoreError.badSlug }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.notFound(slug)
        }
        try FileManager.default.removeItem(at: url)
        reload()
    }
}
