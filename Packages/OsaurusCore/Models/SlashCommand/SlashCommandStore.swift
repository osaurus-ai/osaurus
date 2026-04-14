//
//  SlashCommandStore.swift
//  osaurus
//
//  Persistence for user-defined slash commands.
//  Each command is stored as an individual JSON file in ~/.osaurus/slash-commands/
//

import Foundation

@MainActor
public enum SlashCommandStore {
    // MARK: - Public API

    public static func loadAll() -> [SlashCommand] {
        let directory = commandsDirectory()
        OsaurusPaths.ensureExistsSilent(directory)

        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return
            files
            .filter { $0.pathExtension == "json" }
            .compactMap { file -> SlashCommand? in
                guard let data = try? Data(contentsOf: file),
                    let cmd = try? decoder.decode(SlashCommand.self, from: data)
                else { return nil }
                return cmd
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func save(_ command: SlashCommand) {
        let directory = commandsDirectory()
        OsaurusPaths.ensureExistsSilent(directory)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(command) else { return }
        try? data.write(to: commandFileURL(for: command.id), options: .atomicWrite)
    }

    @discardableResult
    public static func delete(id: UUID) -> Bool {
        let url = commandFileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }

    // MARK: - Private

    private static func commandsDirectory() -> URL {
        OsaurusPaths.root().appendingPathComponent("slash-commands", isDirectory: true)
    }

    private static func commandFileURL(for id: UUID) -> URL {
        commandsDirectory().appendingPathComponent("\(id.uuidString).json")
    }
}
