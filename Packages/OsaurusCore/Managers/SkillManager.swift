//
//  SkillManager.swift
//  osaurus
//
//  Manages skill lifecycle - loading, saving, and catalog generation.
//

import Foundation
import Observation
import SwiftUI

public enum SkillFileError: Error, LocalizedError, Sendable {
    case cannotModifyBuiltIn
    case cannotModifyPluginSkill
    case skillNotFound
    case exportFailed
    case invalidSkillArchive
    case archiveTooLarge(limitBytes: Int64)
    case archiveEntryTooLarge(path: String, limitBytes: Int64)
    case archiveEntryLimitExceeded(limit: Int)
    case archiveEntryTooDeep(path: String, limit: Int)
    case archiveEntryEscapes(path: String)
    case archiveEntryUnsupported(path: String)
    case archiveListingFailed(String)
    case skillAlreadyExists(name: String)
    case skillImportCopyFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .cannotModifyBuiltIn: return L("Cannot modify built-in skills")
        case .cannotModifyPluginSkill: return L("Cannot modify plugin-provided skills")
        case .skillNotFound: return L("Skill not found")
        case .exportFailed: return L("Failed to export skill")
        case .invalidSkillArchive: return L("Invalid skill archive - SKILL.md not found")
        case .archiveTooLarge(let limitBytes):
            return L("Skill archive is larger than the \(Self.formatBytes(limitBytes)) limit")
        case .archiveEntryTooLarge(let path, let limitBytes):
            return L("Skill archive entry \"\(path)\" is larger than the \(Self.formatBytes(limitBytes)) limit")
        case .archiveEntryLimitExceeded(let limit):
            return L("Skill archive contains more than \(limit) entries")
        case .archiveEntryTooDeep(let path, let limit):
            return L("Skill archive entry \"\(path)\" is deeper than the \(limit)-level limit")
        case .archiveEntryEscapes(let path):
            return L("Skill archive entry \"\(path)\" escapes the archive root")
        case .archiveEntryUnsupported(let path):
            return L("Skill archive entry \"\(path)\" is not a regular file or directory")
        case .archiveListingFailed(let details):
            let suffix = details.isEmpty ? "" : ": \(details)"
            return L("Could not inspect skill archive\(suffix)")
        case .skillAlreadyExists(let name):
            return L("A skill named \"\(name)\" already exists")
        case .skillImportCopyFailed(let path, let reason):
            return L("Could not import skill file \"\(path)\": \(reason)")
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes / (1024 * 1024)) MB"
    }
}

@Observable
@MainActor
public final class SkillManager {
    public static let shared = SkillManager()

    public private(set) var skills: [Skill] = []
    public private(set) var isRefreshing = false

    private init() {
        Task { await refresh() }
    }

    // MARK: - CRUD

    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        skills = await SkillStore.loadAll()
    }

    // MARK: - Batch Updates

    /// Depth counter so nested batches collapse to a single trailing refresh.
    private var batchDepth = 0
    /// Skills saved during a batch, so `skill(for:)` (and the file-attachment
    /// helpers) can resolve a just-saved skill without a full `refresh()`.
    private var batchStagedSkills: [UUID: Skill] = [:]

    private var isBatching: Bool { batchDepth > 0 }

    /// Run `body` as a bulk mutation: per-operation refreshes are suppressed
    /// and `skills` is reloaded once when the outermost batch finishes. The
    /// Claude plugin installer otherwise saves 170+ skills one-by-one, making
    /// the Skills view flash as it re-renders the list on every save.
    @discardableResult
    public func batchUpdates<T>(_ body: () async -> T) async -> T {
        batchDepth += 1
        let result = await body()
        batchDepth -= 1
        if batchDepth == 0 {
            batchStagedSkills.removeAll()
            await refresh()
        }
        return result
    }

    /// `refresh()` unless a bulk batch is in flight (see `batchUpdates`).
    private func refreshUnlessBatching() async {
        guard !isBatching else { return }
        await refresh()
    }

    @discardableResult
    public func create(
        name: String,
        description: String = "",
        version: String = "1.0.0",
        author: String? = nil,
        category: String? = nil,
        instructions: String = ""
    ) async -> Skill {
        let skill = Skill(
            name: name,
            description: description,
            version: version,
            author: author,
            category: category,
            instructions: instructions
        )
        await SkillStore.save(skill)
        await refresh()

        Task { await SkillSearchService.shared.indexSkill(skill) }
        return skill
    }

    public func update(_ skill: Skill) async {
        guard !skill.isBuiltIn && !skill.isFromPlugin else { return }
        var updated = skill
        updated.updatedAt = Date()
        if updated.directoryName == nil {
            updated.directoryName = skills.first(where: { $0.id == skill.id })?.directoryName
        }
        await SkillStore.save(updated)
        await refresh()

        Task { await SkillSearchService.shared.indexSkill(updated) }
    }

    @discardableResult
    public func delete(id: UUID) async -> Bool {
        // Prevent deleting plugin-provided skills
        if let skill = skill(for: id), skill.isFromPlugin { return false }
        let result = await SkillStore.delete(id: id)
        if result {
            await refresh()

            Task { await SkillSearchService.shared.removeSkill(id: id) }
        }
        return result
    }

    // MARK: - Plugin Skills

    /// Register a skill from a plugin. If a skill with the same pluginId and name already exists, update it.
    public func registerPluginSkill(_ skill: Skill) async {
        await SkillStore.save(skill)
        await refresh()

        Task { await SkillSearchService.shared.indexSkill(skill) }
    }

    /// Remove all skills associated with a plugin
    public func unregisterPluginSkills(pluginId: String) async {
        let pluginSkillIds = skills.filter { $0.pluginId == pluginId }.map { $0.id }
        for id in pluginSkillIds {
            _ = await SkillStore.delete(id: id)
            Task { await SkillSearchService.shared.removeSkill(id: id) }
        }
        if !pluginSkillIds.isEmpty {
            await refresh()

        }
    }

    /// Returns all skills belonging to a specific plugin
    public func pluginSkills(for pluginId: String) -> [Skill] {
        skills.filter { $0.pluginId == pluginId }
    }

    // MARK: - Lookup

    public func skill(for id: UUID) -> Skill? {
        if isBatching, let staged = batchStagedSkills[id] { return staged }
        return skills.first { $0.id == id }
    }

    /// Case-insensitive name lookup with deterministic collision resolution.
    ///
    /// Skill names are not unique — a user skill can shadow a built-in or a
    /// plugin skill. `skills` array order (built-ins first, then name) made
    /// `first(where:)` pick the *built-in* on a tie, which inverts the
    /// intuitive precedence: someone who deliberately authored a same-named
    /// skill wants theirs. Resolution order:
    ///   1. exact-case name match
    ///   2. user-authored (not built-in, not plugin)
    ///   3. built-in
    ///   4. plugin-provided
    ///   5. stable id tiebreak
    public func skill(named name: String) -> Skill? {
        let matches = skills(named: name)
        guard matches.count > 1 else { return matches.first }
        func tier(_ s: Skill) -> Int {
            if s.isFromPlugin { return 2 }
            return s.isBuiltIn ? 1 : 0
        }
        return matches.min { a, b in
            let aExact = a.name == name
            let bExact = b.name == name
            if aExact != bExact { return aExact }
            if tier(a) != tier(b) { return tier(a) < tier(b) }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// All skills sharing a (case-insensitive) name. More than one element
    /// means `skill(named:)` had to break a tie; callers that surface skills
    /// to the model can use this to disclose the ambiguity.
    public func skills(named name: String) -> [Skill] {
        skills.filter { $0.name.lowercased() == name.lowercased() }
    }

    // MARK: - Import/Export

    @discardableResult
    public func importSkill(from data: Data) async throws -> Skill {
        var skill = try Skill.importFromJSON(data)
        skill = Skill(
            name: skill.name,
            description: skill.description,
            version: skill.version,
            author: skill.author,
            category: skill.category,
            instructions: skill.instructions
        )
        await SkillStore.save(skill)
        await refresh()

        Task { await SkillSearchService.shared.indexSkill(skill) }
        return skill
    }

    @discardableResult
    public func importSkillFromMarkdown(_ content: String) async throws -> Skill {
        try await importSkillFromMarkdown(content, overwriteExisting: false)
    }

    @discardableResult
    public func importSkillFromMarkdown(_ content: String, overwriteExisting: Bool) async throws -> Skill {
        var skill = try Skill.parseAnyFormat(from: content)
        skill = Skill(
            name: skill.name,
            description: skill.description,
            version: skill.version,
            author: skill.author,
            category: skill.category,
            instructions: skill.instructions
        )
        try Self.installImportedSkill(skill, from: nil, overwriteExisting: overwriteExisting)
        await refresh()

        Task { await SkillSearchService.shared.indexSkill(skill) }
        return skill
    }

    /// Import multiple skills at once (batch import from GitHub)
    @discardableResult
    public func importSkillsFromMarkdown(_ skills: [Skill]) async -> [Skill] {
        var imported: [Skill] = []
        for parsedSkill in skills {
            let skill = Skill(
                name: parsedSkill.name,
                description: parsedSkill.description,
                version: parsedSkill.version,
                author: parsedSkill.author,
                category: parsedSkill.category,
                instructions: parsedSkill.instructions
            )
            await SkillStore.save(skill)
            imported.append(skill)
        }
        if !imported.isEmpty {
            await refresh()

            Task {
                for skill in imported {
                    await SkillSearchService.shared.indexSkill(skill)
                }
            }
        }
        return imported
    }

    /// Import skills that came from a plugin and preserve their `pluginId` so
    /// they can be grouped, re-registered on update, and uninstalled in bulk
    /// via `unregisterPluginSkills(pluginId:)`.
    ///
    /// Unlike `importSkillsFromMarkdown(_:)` this path:
    /// - Keeps `pluginId` (required for grouping/uninstall).
    /// - Keeps `category` and `keywords`.
    /// - Reuses the existing skill id when re-importing the same plugin skill.
    @discardableResult
    public func importSkillsPreservingPluginId(_ skills: [Skill]) async -> [Skill] {
        var imported: [Skill] = []
        for parsedSkill in skills {
            let existing = self.skills.first(where: {
                $0.pluginId == parsedSkill.pluginId && $0.name == parsedSkill.name
            })

            let skill = Skill(
                id: existing?.id ?? UUID(),
                name: parsedSkill.name,
                description: parsedSkill.description,
                version: parsedSkill.version,
                author: parsedSkill.author,
                category: parsedSkill.category,
                keywords: parsedSkill.keywords,
                instructions: parsedSkill.instructions,
                isBuiltIn: false,
                createdAt: existing?.createdAt ?? Date(),
                updatedAt: Date(),
                pluginId: parsedSkill.pluginId
            )
            await SkillStore.save(skill)
            if isBatching { batchStagedSkills[skill.id] = skill }
            imported.append(skill)
        }
        if !imported.isEmpty {
            await refreshUnlessBatching()

            Task {
                for skill in imported {
                    await SkillSearchService.shared.indexSkill(skill)
                }
            }
        }
        return imported
    }

    public func exportSkill(_ skill: Skill) throws -> Data {
        try skill.exportToJSON()
    }

    public func exportSkillAsAgentSkills(_ skill: Skill) -> String {
        skill.toAgentSkillsFormat()
    }

    // MARK: - File Management

    public func addReference(to skillId: UUID, name: String, content: Data) async throws {
        guard let skill = skill(for: skillId), !skill.isBuiltIn else {
            throw SkillFileError.cannotModifyBuiltIn
        }
        try await SkillStore.addReference(to: skill, name: name, content: content)
        await refreshUnlessBatching()

    }

    public func addAsset(to skillId: UUID, name: String, content: Data) async throws {
        guard let skill = skill(for: skillId), !skill.isBuiltIn else {
            throw SkillFileError.cannotModifyBuiltIn
        }
        try await SkillStore.addAsset(to: skill, name: name, content: content)
        await refreshUnlessBatching()

    }

    public func removeFile(from skillId: UUID, relativePath: String) async throws {
        guard let skill = skill(for: skillId), !skill.isBuiltIn else {
            throw SkillFileError.cannotModifyBuiltIn
        }
        try await SkillStore.removeFile(from: skill, relativePath: relativePath)
        await refresh()

    }

    public func readFile(from skillId: UUID, relativePath: String) async throws -> Data {
        guard let skill = skill(for: skillId) else {
            throw SkillFileError.skillNotFound
        }
        return try await SkillStore.readFile(from: skill, relativePath: relativePath)
    }

    public func skillDirectory(for skillId: UUID) -> URL? {
        guard let skill = skill(for: skillId) else { return nil }
        return SkillStore.skillDirectory(for: skill)
    }

    // MARK: - ZIP Export/Import

    public func exportSkillAsZip(_ skill: Skill) async throws -> URL {
        try Task.checkCancellation()
        let skillDir = SkillStore.skillDirectory(for: skill)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(skill.xplaceholder_agentSkillsNamex).zip"
        )
        try? FileManager.default.removeItem(at: zipURL)
        do {
            try await FileManager.default.zipItem(at: skillDir, to: zipURL)
            try Task.checkCancellation()
        } catch {
            if (error as? SkillArchiveProcessRunnerError) != .processTerminationIncomplete {
                try? FileManager.default.removeItem(at: zipURL)
            }
            throw error
        }
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw SkillFileError.exportFailed
        }
        return zipURL
    }

    @discardableResult
    public func importSkillFromZip(_ zipURL: URL) async throws -> Skill {
        let result = try await importSkillFromZip(zipURL, overwriteExisting: false)
        return result.skill
    }

    @discardableResult
    public func importSkillFromZip(
        _ zipURL: URL,
        overwriteExisting: Bool,
        policy: SkillImportPolicy = .default
    ) async throws -> SkillImportResult {
        let result = try await Self.performZipImport(
            zipURL,
            overwriteExisting: overwriteExisting,
            policy: policy
        )

        await refresh()

        Task { await SkillSearchService.shared.indexSkill(result.skill) }
        return result
    }

    /// Nonisolated async work runs off the main actor while preserving the
    /// caller task's cancellation state through validation and extraction.
    nonisolated private static func performZipImport(
        _ zipURL: URL,
        overwriteExisting: Bool,
        policy: SkillImportPolicy
    ) async throws -> SkillImportResult {
        try Task.checkCancellation()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        var cleanupTransferredToReaper = false
        defer {
            if !cleanupTransferredToReaper {
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        try policy.validateArchiveBeforeExtraction(zipURL)
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        do {
            try await FileManager.default.unzipItem(at: zipURL, to: tempDir)
        } catch {
            if (error as? SkillArchiveProcessRunnerError) == .processTerminationIncomplete {
                cleanupTransferredToReaper = true
            }
            throw error
        }

        try Task.checkCancellation()
        let importPlan = try policy.scanExtractedTree(at: tempDir)
        let content = try String(contentsOf: importPlan.skillMarkdownURL, encoding: .utf8)
        let parsed = try Skill.parseAnyFormat(from: content)
        try Task.checkCancellation()

        let skill = Skill(
            name: parsed.name,
            description: parsed.description,
            version: parsed.version,
            author: parsed.author,
            category: parsed.category,
            instructions: parsed.instructions,
            directoryName: parsed.xplaceholder_agentSkillsNamex
        )

        try Self.installImportedSkill(
            skill,
            from: importPlan.skillRootURL,
            overwriteExisting: overwriteExisting,
            stagingBase: tempDir
        )

        let notes: [String]
        if importPlan.ignoredSkillMarkdownPaths.isEmpty {
            notes = []
        } else {
            let ignored = importPlan.ignoredSkillMarkdownPaths.joined(separator: ", ")
            notes = [
                L("Imported \(importPlan.selectedSkillMarkdownPath); ignored additional SKILL.md files: \(ignored)")
            ]
        }
        return SkillImportResult(skill: skill, notes: notes)
    }

    nonisolated private static func installImportedSkill(
        _ skill: Skill,
        from sourceSkillRoot: URL?,
        overwriteExisting: Bool,
        stagingBase: URL = FileManager.default.temporaryDirectory
    ) throws {
        let fileManager = FileManager.default
        let destination = SkillStore.skillDirectory(for: skill)
        let stage = stagingBase.appendingPathComponent("skill-import-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stage) }

        try fileManager.createDirectory(at: stage, withIntermediateDirectories: true)
        try skill.toAgentSkillsFormatWithId().write(
            to: stage.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        if let sourceSkillRoot {
            for subdirectory in ["references", "assets"] {
                let source = sourceSkillRoot.appendingPathComponent(subdirectory, isDirectory: true)
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory) {
                    guard isDirectory.boolValue else {
                        throw SkillFileError.skillImportCopyFailed(
                            path: subdirectory,
                            reason: L("Expected directory")
                        )
                    }
                    try copyImportedSubdirectory(
                        named: subdirectory,
                        from: source,
                        to: stage.appendingPathComponent(subdirectory, isDirectory: true)
                    )
                }
            }
        }

        try installStagedSkillDirectory(
            stage,
            to: destination,
            skillName: skill.name,
            overwriteExisting: overwriteExisting
        )
    }

    nonisolated private static func copyImportedSubdirectory(
        named name: String,
        from source: URL,
        to destination: URL
    ) throws {
        let fileManager = FileManager.default
        let sourceRoot = source.standardizedFileURL
        let destinationRoot = destination.standardizedFileURL
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        guard
            let enumerator = fileManager.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        else {
            throw SkillFileError.skillImportCopyFailed(path: name, reason: L("Could not inspect directory"))
        }

        for case let entry as URL in enumerator {
            let relativePath = try relativePath(for: entry, in: sourceRoot)
            let importPath = "\(name)/\(relativePath)"
            do {
                let values = try entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                guard values.isSymbolicLink != true else {
                    throw SkillFileError.archiveEntryUnsupported(path: importPath)
                }

                let target = destinationRoot.appendingPathComponent(relativePath)
                try ensureContained(target, in: destinationRoot)

                if values.isDirectory == true {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                } else if values.isRegularFile == true {
                    try fileManager.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try fileManager.copyItem(at: entry, to: target)
                } else {
                    throw SkillFileError.archiveEntryUnsupported(path: importPath)
                }
            } catch let error as SkillFileError {
                throw error
            } catch {
                throw SkillFileError.skillImportCopyFailed(path: importPath, reason: error.localizedDescription)
            }
        }
    }

    nonisolated private static func installStagedSkillDirectory(
        _ stage: URL,
        to destination: URL,
        skillName: String,
        overwriteExisting: Bool
    ) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)

        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory)
        if exists {
            guard isDirectory.boolValue else {
                throw SkillFileError.skillImportCopyFailed(
                    path: destination.lastPathComponent,
                    reason: L("Destination exists and is not a directory")
                )
            }
            guard overwriteExisting else {
                throw SkillFileError.skillAlreadyExists(name: skillName)
            }
        }

        if !exists {
            try fileManager.moveItem(at: stage, to: destination)
            return
        }

        let backup = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).import-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try fileManager.moveItem(at: stage, to: destination)
            try? fileManager.removeItem(at: backup)
        } catch {
            try? fileManager.removeItem(at: destination)
            try? fileManager.moveItem(at: backup, to: destination)
            throw SkillFileError.skillImportCopyFailed(
                path: destination.lastPathComponent,
                reason: error.localizedDescription
            )
        }
    }

    nonisolated private static func relativePath(for fileURL: URL, in baseDirectory: URL) throws -> String {
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        guard fileComponents.count > baseComponents.count,
            Array(fileComponents.prefix(baseComponents.count)) == baseComponents
        else {
            throw SkillFileError.archiveEntryEscapes(path: fileURL.path)
        }
        return fileComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }

    nonisolated private static func ensureContained(_ fileURL: URL, in baseDirectory: URL) throws {
        let fileComponents = fileURL.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let baseComponents = baseDirectory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard fileComponents.count >= baseComponents.count,
            Array(fileComponents.prefix(baseComponents.count)) == baseComponents
        else {
            throw SkillFileError.archiveEntryEscapes(path: fileURL.path)
        }
    }

    // MARK: - Catalog & Instructions

    public func loadInstructions(for skillNames: [String]) async -> [String: String] {
        var result: [String: String] = [:]
        for name in skillNames {
            if let skill = skill(named: name) {
                result[name] = await buildFullInstructions(for: skill)
            }
        }
        return result
    }

    public func loadInstructions(forIds ids: [UUID]) async -> [UUID: String] {
        var result: [UUID: String] = [:]
        for id in ids {
            if let skill = skill(for: id) {
                result[id] = await buildFullInstructions(for: skill)
            }
        }
        return result
    }

    /// Instructions plus reference materials, the complete "skill is active"
    /// payload. Both delivery paths use this — the `/skill-name` slash
    /// injection and `capabilities_load skill/<name>` — so a skill behaves
    /// the same however it was invoked.
    ///
    /// `referenceBudget` caps the total characters of reference content
    /// (NOT instructions). The slash path injects into the system prompt of
    /// a single message and uses the default unlimited budget; the
    /// capability-load path rides in a tool result that persists in history,
    /// so it passes a finite budget and oversized references collapse to a
    /// named omission note.
    public func buildFullInstructions(
        for skill: Skill,
        referenceBudget: Int = .max
    ) async -> String {
        var sections = [skill.instructions]

        if !skill.references.isEmpty {
            let refs = await loadReferenceContents(for: skill, budget: referenceBudget)
            if !refs.isEmpty {
                sections.append("\n## Reference Materials\n\n\(refs)")
            }
        }

        return sections.joined(separator: "\n")
    }

    private func loadReferenceContents(for skill: Skill, budget: Int = .max) async -> String {
        let textExtensions: Set<String> = [
            "md", "txt", "json", "yaml", "yml", "xml", "html", "css", "js", "ts",
            "swift", "py", "rb", "go", "rs", "java", "kt", "c", "cpp", "h", "hpp",
            "sql", "sh", "bash", "zsh", "toml", "ini", "cfg", "conf",
        ]

        var contents: [String] = []
        var usedBudget = 0
        var omittedNames: [String] = []
        for file in skill.references {
            let ext = (file.name as NSString).pathExtension.lowercased()
            guard textExtensions.contains(ext) || ext.isEmpty else { continue }
            guard file.size < 100_000 else {
                contents.append("### \(file.name)\n*File too large (>\(formatSize(file.size)))*\n")
                continue
            }
            // Once the budget is exhausted, keep scanning only to name what
            // was left out — a silent drop would let the model assume the
            // skill has no further reference material.
            guard usedBudget < budget else {
                omittedNames.append(file.name)
                continue
            }

            do {
                let data = try await SkillStore.readFile(from: skill, relativePath: file.relativePath)
                if let text = String(data: data, encoding: .utf8) {
                    if usedBudget + text.count > budget {
                        omittedNames.append(file.name)
                        continue
                    }
                    usedBudget += text.count
                    contents.append("### \(file.name)\n\n```\n\(text)\n```\n")
                }
            } catch {
                // Skip unreadable files
            }
        }
        if !omittedNames.isEmpty {
            contents.append(
                "### Omitted references\n*\(omittedNames.count) reference file(s) omitted to keep "
                    + "this load small: \(omittedNames.joined(separator: ", ")). Invoking the skill "
                    + "with its slash command includes them in full.*\n"
            )
        }
        return contents.joined(separator: "\n")
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    // MARK: - Statistics

    public var customCount: Int { skills.filter { !$0.isBuiltIn }.count }
    public var categories: [String] { Array(Set(skills.compactMap { $0.category })).sorted() }
}

// MARK: - FileManager ZIP Extension

extension FileManager {
    func unzipItem(
        at sourceURL: URL,
        to destinationURL: URL,
        configuration: SkillArchiveProcessConfiguration = .default
    ) async throws {
        try Task.checkCancellation()
        let result = try SkillArchiveProcessRunner.run(
            executablePath: "/usr/bin/unzip",
            arguments: ["-o", "-q", "-d", destinationURL.path, "--", sourceURL.path],
            timeoutSeconds: 60,
            configuration: configuration.withDeferredCleanupURL(destinationURL)
        )
        try Task.checkCancellation()

        if result.timedOut {
            throw NSError(
                domain: "FileManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unzip timed out after 60 seconds"]
            )
        }

        if result.terminationStatus != 0 {
            throw NSError(
                domain: "FileManager",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Unzip failed: \(result.output)"]
            )
        }
    }

    func zipItem(
        at sourceURL: URL,
        to destinationURL: URL,
        configuration: SkillArchiveProcessConfiguration = .default
    ) async throws {
        try Task.checkCancellation()
        let result = try SkillArchiveProcessRunner.run(
            executablePath: "/usr/bin/zip",
            arguments: ["-r", "-q", "-nw", destinationURL.path, "--", sourceURL.lastPathComponent],
            currentDirectoryURL: sourceURL.deletingLastPathComponent(),
            timeoutSeconds: 120,
            configuration: configuration.withDeferredCleanupURL(destinationURL)
        )
        try Task.checkCancellation()

        if result.timedOut {
            throw NSError(
                domain: "FileManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Zip timed out after 120 seconds"]
            )
        }

        if result.terminationStatus != 0 {
            throw NSError(
                domain: "FileManager",
                code: Int(result.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Zip failed: \(result.output)"]
            )
        }
    }
}
