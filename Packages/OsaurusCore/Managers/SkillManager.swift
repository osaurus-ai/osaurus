//
//  SkillManager.swift
//  osaurus
//
//  Manages skill lifecycle - loading, saving, enabling, and catalog generation.
//

import Foundation
import Observation
import SwiftUI

public enum SkillFileError: Error, LocalizedError {
    case cannotModifyBuiltIn
    case cannotModifyPluginSkill
    case skillNotFound
    case exportFailed
    case invalidSkillArchive

    public var errorDescription: String? {
        switch self {
        case .cannotModifyBuiltIn: return "Cannot modify built-in skills"
        case .cannotModifyPluginSkill: return "Cannot modify plugin-provided skills"
        case .skillNotFound: return "Skill not found"
        case .exportFailed: return "Failed to export skill"
        case .invalidSkillArchive: return "Invalid skill archive - SKILL.md not found"
        }
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
        skills.first { $0.id == id }
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
        var skill = try Skill.parseAnyFormat(from: content)
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
        await refresh()

    }

    public func addAsset(to skillId: UUID, name: String, content: Data) async throws {
        guard let skill = skill(for: skillId), !skill.isBuiltIn else {
            throw SkillFileError.cannotModifyBuiltIn
        }
        try await SkillStore.addAsset(to: skill, name: name, content: content)
        await refresh()

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
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            Task.detached {
                try? FileManager.default.removeItem(at: tempDir)
            }
        }

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try await FileManager.default.unzipItem(at: zipURL, to: tempDir)

        guard let skillMdURL = findSkillMd(in: tempDir) else {
            throw SkillFileError.invalidSkillArchive
        }

        let skillDir = skillMdURL.deletingLastPathComponent()
        let content = try String(contentsOf: skillMdURL, encoding: .utf8)
        var skill = try Skill.parseAnyFormat(from: content)

        skill = Skill(
            name: skill.name,
            description: skill.description,
            version: skill.version,
            author: skill.author,
            category: skill.category,
            enabled: true,
            instructions: skill.instructions,
            directoryName: skill.xplaceholder_agentSkillsNamex
        )

        await SkillStore.save(skill)

        // Copy associated files
        let destDir = SkillStore.skillDirectory(for: skill)
        for subdir in ["references", "assets"] {
            let sourceSubdir = skillDir.appendingPathComponent(subdir)
            let destSubdir = destDir.appendingPathComponent(subdir)

            if FileManager.default.fileExists(atPath: sourceSubdir.path) {
                try? FileManager.default.createDirectory(at: destSubdir, withIntermediateDirectories: true)
                if let files = try? FileManager.default.contentsOfDirectory(
                    at: sourceSubdir,
                    includingPropertiesForKeys: nil
                ) {
                    for file in files {
                        try? FileManager.default.copyItem(
                            at: file,
                            to: destSubdir.appendingPathComponent(file.lastPathComponent)
                        )
                    }
                }
            }
        }

        await refresh()

        Task { await SkillSearchService.shared.indexSkill(skill) }
        return skill
    }

    private func findSkillMd(in directory: URL) -> URL? {
        let rootSkillMd = directory.appendingPathComponent("SKILL.md")
        if FileManager.default.fileExists(atPath: rootSkillMd.path) {
            return rootSkillMd
        }

        if let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for item in contents {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                    let skillMd = item.appendingPathComponent("SKILL.md")
                    if FileManager.default.fileExists(atPath: skillMd.path) {
                        return skillMd
                    }
                }
            }
        }
        return nil
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
        var sections = [skill.instructions]

        if !skill.references.isEmpty {
            let refs = await loadReferenceContents(for: skill)
            if !refs.isEmpty {
                sections.append("\n## Reference Materials\n\n\(refs)")
            }
        }

        return sections.joined(separator: "\n")
    }

    private func loadReferenceContents(for skill: Skill) async -> String {
        let textExtensions: Set<String> = [
            "md", "txt", "json", "yaml", "yml", "xml", "html", "css", "js", "ts",
            "swift", "py", "rb", "go", "rs", "java", "kt", "c", "cpp", "h", "hpp",
            "sql", "sh", "bash", "zsh", "toml", "ini", "cfg", "conf",
        ]

        var contents: [String] = []
        for file in skill.references {
            let ext = (file.name as NSString).pathExtension.lowercased()
            guard textExtensions.contains(ext) || ext.isEmpty else { continue }
            guard file.size < 100_000 else {
                contents.append("### \(file.name)\n*File too large (>\(formatSize(file.size)))*\n")
                continue
            }

            do {
                let data = try await SkillStore.readFile(from: skill, relativePath: file.relativePath)
                if let text = String(data: data, encoding: .utf8) {
                    contents.append("### \(file.name)\n\n```\n\(text)\n```\n")
                }
            } catch {
                // Skip unreadable files
            }
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
