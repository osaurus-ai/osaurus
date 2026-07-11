//
//  SkillManager.swift
//  osaurus
//
//  Manages skill lifecycle - loading, saving, enabling, and catalog generation.
//

import Foundation
import Observation
import SwiftUI

actor SkillReferenceBudget {
    private var remainingFiles: Int
    private var remainingBytes: Int

    init(maxFiles: Int = 20, maxBytes: Int = 200_000) {
        remainingFiles = max(0, maxFiles)
        remainingBytes = max(0, maxBytes)
    }

    func claim(bytes: Int) -> Bool {
        guard bytes >= 0, remainingFiles > 0, bytes <= remainingBytes else { return false }
        remainingFiles -= 1
        remainingBytes -= bytes
        return true
    }
}

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
        // Check if we already have a skill from this plugin with the same name
        if let existing = skills.first(where: { $0.pluginId == skill.pluginId && $0.name == skill.name }) {
            // Update existing skill but preserve enabled state
            var updated = skill
            updated.enabled = existing.enabled
            await SkillStore.save(updated)
        } else {
            await SkillStore.save(skill)
        }
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

    public func setEnabled(_ enabled: Bool, for id: UUID) async {
        guard var skill = skill(for: id) else { return }
        skill.enabled = enabled
        skill.updatedAt = Date()

        // Create a saveable copy for built-in skills
        if skill.isBuiltIn {
            let saveable = Skill(
                id: skill.id,
                name: skill.name,
                description: skill.description,
                version: skill.version,
                author: skill.author,
                category: skill.category,
                enabled: enabled,
                instructions: skill.instructions,
                isBuiltIn: true,
                createdAt: skill.createdAt,
                updatedAt: Date()
            )
            await SkillStore.save(saveable)
        } else {
            await SkillStore.save(skill)
        }

        await refresh()

    }

    // MARK: - Lookup

    public func skill(for id: UUID) -> Skill? {
        if isBatching, let staged = batchStagedSkills[id] { return staged }
        return skills.first { $0.id == id }
    }

    public func skill(named name: String) -> Skill? {
        skills.first { $0.name.lowercased() == name.lowercased() }
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
    /// - Honours an existing-skill `enabled` state when re-importing the same
    ///   plugin skill, just like `registerPluginSkill(_:)`.
    @discardableResult
    public func importSkillsPreservingPluginId(_ skills: [Skill]) async -> [Skill] {
        var imported: [Skill] = []
        for parsedSkill in skills {
            // Honour existing enabled state if this plugin+name already exists.
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
                enabled: existing?.enabled ?? parsedSkill.enabled,
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
        let skillDir = SkillStore.skillDirectory(for: skill)
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(skill.xplaceholder_agentSkillsNamex).zip"
        )
        try? FileManager.default.removeItem(at: zipURL)
        try await FileManager.default.zipItem(at: skillDir, to: zipURL)
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
        // All filesystem work (unzip, SKILL.md read, nested file copies) runs
        // off the main actor — a large bundle would otherwise block the UI and
        // trip an app-hang. Only the trailing `refresh()` (which mutates
        // observed state) hops back to the main actor.
        let result = try await Task.detached(priority: .userInitiated) {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString
            )
            defer { try? FileManager.default.removeItem(at: tempDir) }

            try policy.validateArchiveBeforeExtraction(zipURL)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            try await FileManager.default.unzipItem(at: zipURL, to: tempDir)

            let importPlan = try policy.scanExtractedTree(at: tempDir)
            let content = try String(contentsOf: importPlan.skillMarkdownURL, encoding: .utf8)
            let parsed = try Skill.parseAnyFormat(from: content)

            let skill = Skill(
                name: parsed.name,
                description: parsed.description,
                version: parsed.version,
                author: parsed.author,
                category: parsed.category,
                enabled: true,
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
        }.value

        await refresh()

        Task { await SkillSearchService.shared.indexSkill(result.skill) }
        return result
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

    /// Builds the combined skill instructions section for an agent in manual mode,
    /// or returns nil if the agent has no selected skills or is not in manual mode.
    public func manualSkillPromptSection(for agentId: UUID) async -> String? {
        guard let skillNames = AgentManager.shared.effectiveManualSkillNames(for: agentId),
            !skillNames.isEmpty
        else { return nil }
        let instructions = await loadInstructions(for: skillNames)
        guard !instructions.isEmpty else { return nil }
        let sections = skillNames.compactMap { name -> String? in
            guard let body = instructions[name] else { return nil }
            return "## Skill: \(name)\n\n\(body)"
        }
        return sections.joined(separator: "\n\n")
    }

    /// Builds the combined skill instructions section for an agent's enabled skills,
    /// regardless of tool selection mode. Returns nil when the agent has not been
    /// seeded yet (legacy behaviour: skills only inject in Manual via the older
    /// `manualSkillPromptSection`) or has no enabled skills.
    public func enabledSkillPromptSection(for agentId: UUID) async -> String? {
        guard let skillNames = AgentManager.shared.effectiveEnabledSkillNames(for: agentId),
            !skillNames.isEmpty
        else { return nil }
        let instructions = await loadInstructions(for: skillNames)
        guard !instructions.isEmpty else { return nil }
        let sections = skillNames.compactMap { name -> String? in
            guard let body = instructions[name] else { return nil }
            return "## Skill: \(name)\n\n\(body)"
        }
        return sections.joined(separator: "\n\n")
    }

    public func loadInstructions(for skillNames: [String]) async -> [String: String] {
        var result: [String: String] = [:]
        for name in skillNames {
            if let skill = skill(named: name), skill.enabled {
                result[name] = await buildFullInstructions(for: skill)
            }
        }
        return result
    }

    public func loadInstructions(forIds ids: [UUID]) async -> [UUID: String] {
        var result: [UUID: String] = [:]
        for id in ids {
            if let skill = skill(for: id), skill.enabled {
                result[id] = await buildFullInstructions(for: skill)
            }
        }
        return result
    }

    public func buildFullInstructions(for skill: Skill) async -> String {
        await buildFullInstructions(for: skill, budget: SkillReferenceBudget())
    }

    func buildFullInstructions(for skill: Skill, budget: SkillReferenceBudget) async -> String {
        var sections = [skill.instructions]

        if !skill.references.isEmpty {
            let refs = await loadReferenceContents(for: skill, budget: budget)
            if !refs.isEmpty {
                sections.append("\n## Reference Materials\n\n\(refs)")
            }
        }

        let supportInventory = await buildSupportFileInventory(for: skill)
        if !supportInventory.isEmpty {
            sections.append("\n## Skill Package Files\n\n\(supportInventory)")
        }

        return sections.joined(separator: "\n")
    }

    private func buildSupportFileInventory(for skill: Skill) async -> String {
        let supportFiles = await Task.detached(priority: .utility) {
            SkillStore.supportFiles(from: skill)
        }.value
        guard !supportFiles.isEmpty else { return "" }

        var lines = [
            "Supporting files are listed for orientation only; loading a skill never executes them or reads their contents from scripts, assets, or templates.",
            "Reference materials, when present, are loaded separately above.",
            "Paths are relative to the skill package root. Inspect text scripts before running them, and run helper scripts only through an enabled execution tool when the user explicitly asks for execution.",
            "The inventory is capped at \(SkillStore.supportFileInventoryLimit) support files.",
            "",
        ]

        for file in supportFiles {
            lines.append("- \(promptSafeSkillPath(file.relativePath)) (\(formatSize(file.size)))")
        }

        return lines.joined(separator: "\n")
    }

    private func promptSafeSkillPath(_ path: String) -> String {
        let directionalFormattingControls = CharacterSet(
            charactersIn: "\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"
        )
        var sanitized = String.UnicodeScalarView()
        for scalar in path.unicodeScalars {
            let shouldReplace = CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.newlines.contains(scalar)
                || directionalFormattingControls.contains(scalar)
            if shouldReplace {
                sanitized.append(contentsOf: "?".unicodeScalars)
            } else {
                sanitized.append(scalar)
            }
        }
        return String(sanitized)
    }
    private func loadReferenceContents(
        for skill: Skill,
        budget: SkillReferenceBudget
    ) async -> String {
        let textExtensions: Set<String> = [
            "md", "txt", "json", "yaml", "yml", "xml", "html", "css", "js", "ts",
            "swift", "py", "rb", "go", "rs", "java", "kt", "c", "cpp", "h", "hpp",
            "sql", "sh", "bash", "zsh", "toml", "ini", "cfg", "conf",
        ]

        var contents: [String] = []
        var omittedCount = 0
        let perReferenceLimit = 100_000
        for file in skill.references {
            let ext = (file.name as NSString).pathExtension.lowercased()
            guard textExtensions.contains(ext) || ext.isEmpty else { continue }
            guard file.size < Int64(perReferenceLimit) else {
                contents.append("### \(file.name)\n*File too large (>\(formatSize(file.size)))*\n")
                continue
            }

            do {
                let data = try await SkillStore.readFile(
                    from: skill,
                    relativePath: file.relativePath,
                    maxBytes: perReferenceLimit
                )
                guard await budget.claim(bytes: data.count) else {
                    omittedCount += 1
                    continue
                }
                if let text = String(data: data, encoding: .utf8) {
                    contents.append("### \(file.name)\n\n```\n\(text)\n```\n")
                }
            } catch {
                // Skip unreadable files
            }
        }
        if omittedCount > 0 {
            contents.append("*\(omittedCount) reference file(s) omitted due to skill reference budget.*\n")
        }
        return contents.joined(separator: "\n")
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    // MARK: - Statistics

    public var enabledCount: Int { skills.filter { $0.enabled }.count }
    public var customCount: Int { skills.filter { !$0.isBuiltIn }.count }
    public var categories: [String] { Array(Set(skills.compactMap { $0.category })).sorted() }
}

// MARK: - FileManager ZIP Extension

extension FileManager {
    func unzipItem(at sourceURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-o", "-q", sourceURL.path, "-d", destinationURL.path]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw NSError(
                    domain: "FileManager",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Unzip failed: \(output)"]
                )
            }
        }.value
    }

    func zipItem(at sourceURL: URL, to destinationURL: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = sourceURL.deletingLastPathComponent()
            process.arguments = ["-r", "-q", destinationURL.path, sourceURL.lastPathComponent]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            if process.terminationStatus != 0 {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw NSError(
                    domain: "FileManager",
                    code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "Zip failed: \(output)"]
                )
            }
        }.value
    }
}
