//
//  ProjectStore.swift
//  osaurus
//
//  Persistence for Projects (one JSON file per project, like AgentStore)
//

import Foundation

@MainActor
public enum ProjectStore {
    /// Load all projects sorted by name.
    public static func loadAll() -> [Project] {
        let directory = OsaurusPaths.projects()
        OsaurusPaths.ensureExistsSilent(directory)

        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var projects: [Project] = []
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                projects.append(try decoder.decode(Project.self, from: data))
            } catch {
                print("[Osaurus] Failed to load project from \(file.lastPathComponent): \(error)")
            }
        }
        return projects.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Save a project (creates or updates).
    public static func save(_ project: Project) {
        let url = fileURL(for: project.id)
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(project)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save project \(project.id): \(error)")
        }
    }

    /// Delete a project by ID. Sessions keep their `projectId`-cleanup at
    /// the manager layer; the store only removes the record.
    @discardableResult
    public static func delete(id: UUID) -> Bool {
        do {
            try FileManager.default.removeItem(at: fileURL(for: id))
            return true
        } catch {
            print("[Osaurus] Failed to delete project \(id): \(error)")
            return false
        }
    }

    private static func fileURL(for id: UUID) -> URL {
        OsaurusPaths.projects().appendingPathComponent("\(id.uuidString).json")
    }
}
