//
//  SkillStore.swift
//  osaurus
//
//  Persistence for Skills using directory-based storage following Agent Skills spec.
//  Directory structure: skills/{skill-name}/SKILL.md with optional references/ and assets/
//

import Foundation

@MainActor
public enum SkillStore {

    // MARK: - Public API

    /// Load all skills sorted by name, including built-ins
    public static func loadAll() -> [Skill] {
        let directory = skillsDirectory()
        OsaurusPaths.ensureExistsSilent(directory)
        migrateOldFormat()

        var savedSkills: [UUID: Skill] = [:]

        // Load custom skills (non-hidden directories)
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for item in contents {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                    isDirectory.boolValue,
                    let skill = loadFromDirectory(item)
                else {
                    continue
                }
                savedSkills[skill.id] = skill
            }
        }

        // Load built-in skill states (hidden directories starting with .)
        var builtInStates: [UUID: Skill] = [:]
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []  // Include hidden files
        ) {
            for item in contents {
                let name = item.lastPathComponent
                // Only process hidden directories that look like UUIDs
                guard name.hasPrefix("."),
                    name.count > 1,
                    let skill = loadFromDirectory(item)
                else {
                    continue
                }
                builtInStates[skill.id] = skill
            }
        }

        // Merge built-in skills with saved state
        var skills: [Skill] = Skill.builtInSkills.map { builtIn in
            if let saved = builtInStates[builtIn.id] {
                return Skill(
                    id: builtIn.id,
                    name: builtIn.name,
                    description: builtIn.description,
                    version: builtIn.version,
                    author: builtIn.author,
                    category: builtIn.category,
                    enabled: saved.enabled,
                    instructions: builtIn.instructions,
                    isBuiltIn: true,
                    createdAt: builtIn.createdAt,
                    updatedAt: saved.updatedAt,
                    references: builtIn.references,
                    assets: builtIn.assets,
                    directoryName: builtIn.directoryName
                )
            }
            return builtIn
        }

        // Add custom skills
        let builtInIds = Set(Skill.builtInSkills.map { $0.id })
        for (id, skill) in savedSkills where !builtInIds.contains(id) {
            skills.append(skill)
        }

        return skills.sorted { a, b in
            if a.isBuiltIn != b.isBuiltIn { return a.isBuiltIn }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Load a specific skill by ID
    public static func load(id: UUID) -> Skill? {
        if let builtIn = Skill.builtInSkills.first(where: { $0.id == id }) {
            return builtIn
        }

        let directory = skillsDirectory()
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }

        for item in contents {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                let skill = loadFromDirectory(item),
                skill.id == id
            else {
                continue
            }
            return skill
        }
        return nil
    }

    /// Save a skill to disk
    public static func save(_ skill: Skill) {
        if skill.isBuiltIn {
            saveBuiltInState(skill)
            return
        }

        let dirName = skill.directoryName ?? skill.agentSkillsName
        let skillDir = skillsDirectory().appendingPathComponent(dirName)

        do {
            try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)

            let skillMdPath = skillDir.appendingPathComponent("SKILL.md")
            try skill.toAgentSkillsFormatWithId().write(to: skillMdPath, atomically: true, encoding: .utf8)

            if !skill.references.isEmpty {
                try FileManager.default.createDirectory(
                    at: skillDir.appendingPathComponent("references"),
                    withIntermediateDirectories: true
                )
            }
            if !skill.assets.isEmpty {
                try FileManager.default.createDirectory(
                    at: skillDir.appendingPathComponent("assets"),
                    withIntermediateDirectories: true
                )
            }
        } catch {
            print("[Osaurus] Failed to save skill \(skill.id): \(error)")
        }
    }

    /// Delete a skill by ID
    @discardableResult
    public static func delete(id: UUID) -> Bool {
        guard !Skill.builtInSkills.contains(where: { $0.id == id }) else {
            return false
        }

        let directory = skillsDirectory()
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return false
        }

        for item in contents {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                let skill = loadFromDirectory(item),
                skill.id == id
            else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: item)
                return true
            } catch {
                return false
            }
        }
        return false
    }

    /// Check if a skill exists
    public static func exists(id: UUID) -> Bool {
        Skill.builtInSkills.contains(where: { $0.id == id }) || load(id: id) != nil
    }

    /// Get the directory URL for a skill
    public static func skillDirectory(for skill: Skill) -> URL {
        let dirName = skill.directoryName ?? skill.agentSkillsName
        return skillsDirectory().appendingPathComponent(dirName)
    }

    // MARK: - File Operations

    /// Add a reference file to a skill
    public static func addReference(to skill: Skill, name: String, content: Data) throws {
        let refsDir = skillDirectory(for: skill).appendingPathComponent("references")
        try FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)
        try content.write(to: refsDir.appendingPathComponent(name))
    }

    /// Add an asset file to a skill
    public static func addAsset(to skill: Skill, name: String, content: Data) throws {
        let assetsDir = skillDirectory(for: skill).appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)
        try content.write(to: assetsDir.appendingPathComponent(name))
    }

    /// Remove a file from a skill
    public static func removeFile(from skill: Skill, relativePath: String) throws {
        let fileURL = skillDirectory(for: skill).appendingPathComponent(relativePath)
        try FileManager.default.removeItem(at: fileURL)
    }

    /// Read content of a skill file
    public static func readFile(from skill: Skill, relativePath: String) throws -> Data {
        let fileURL = skillDirectory(for: skill).appendingPathComponent(relativePath)
        return try Data(contentsOf: fileURL)
    }

    // MARK: - Private

    private static func skillsDirectory() -> URL {
        OsaurusPaths.skills()
    }

    private static func loadFromDirectory(_ directoryURL: URL) -> Skill? {
        let skillMdPath = directoryURL.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: skillMdPath.path) else { return nil }

        do {
            let content = try String(contentsOf: skillMdPath, encoding: .utf8)
            let parsed = try Skill.parseAnyFormat(from: content)

            return Skill(
                id: parsed.id,
                name: parsed.name,
                description: parsed.description,
                version: parsed.version,
                author: parsed.author,
                category: parsed.category,
                enabled: parsed.enabled,
                instructions: parsed.instructions,
                isBuiltIn: parsed.isBuiltIn,
                createdAt: parsed.createdAt,
                updatedAt: parsed.updatedAt,
                references: loadFilesFromSubdirectory(directoryURL, subdirectory: "references"),
                assets: loadFilesFromSubdirectory(directoryURL, subdirectory: "assets"),
                directoryName: directoryURL.lastPathComponent,
                pluginId: parsed.pluginId
            )
        } catch {
            print("[Osaurus] Failed to load skill from \(directoryURL.lastPathComponent): \(error)")
            return nil
        }
    }

    private static func loadFilesFromSubdirectory(_ skillDir: URL, subdirectory: String) -> [SkillFile] {
        let subDir = skillDir.appendingPathComponent(subdirectory)
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: subDir,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return files.compactMap { fileURL -> SkillFile? in
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]) else { return nil }
            return SkillFile(
                name: fileURL.lastPathComponent,
                relativePath: "\(subdirectory)/\(fileURL.lastPathComponent)",
                size: Int64(values.fileSize ?? 0)
            )
        }
    }

    private static func saveBuiltInState(_ skill: Skill) {
        let dirName = ".\(skill.id.uuidString)"
        let skillDir = skillsDirectory().appendingPathComponent(dirName)

        do {
            try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
            let skillMdPath = skillDir.appendingPathComponent("SKILL.md")
            try skill.toAgentSkillsFormatWithId().write(to: skillMdPath, atomically: true, encoding: .utf8)
        } catch {
            print("[Osaurus] Failed to save built-in skill state: \(error)")
        }
    }

    private static func migrateOldFormat() {
        let directory = skillsDirectory()
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return
        }

        for file in files where file.pathExtension == "md" {
            do {
                let content = try String(contentsOf: file, encoding: .utf8)
                let skill = try Skill.parseAnyFormat(from: content)
                let dirName = skill.directoryName ?? skill.agentSkillsName
                let skillDir = directory.appendingPathComponent(dirName)

                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: skillDir.path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }

                try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
                try skill.toAgentSkillsFormatWithId().write(
                    to: skillDir.appendingPathComponent("SKILL.md"),
                    atomically: true,
                    encoding: .utf8
                )
                try FileManager.default.removeItem(at: file)
                print("[Osaurus] Migrated skill: \(skill.name)")
            } catch {
                print("[Osaurus] Failed to migrate \(file.lastPathComponent): \(error)")
            }
        }
    }
}
