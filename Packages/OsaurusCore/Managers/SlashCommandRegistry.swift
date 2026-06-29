//
//  SlashCommandRegistry.swift
//  osaurus
//
//  Merges built-in commands, user-defined commands, and enabled Skills into a
//  single list. Provides fuzzy filtering used by the slash command popup.
//

import Foundation
import Observation

@Observable
@MainActor
public final class SlashCommandRegistry {
    public static let shared = SlashCommandRegistry()

    /// User-defined custom commands loaded from disk.
    public private(set) var customCommands: [SlashCommand] = []

    /// True while the slash command popup is visible in any chat window.
    /// Used by the global key monitor in ChatView to suppress window-close on Escape.
    public var isPopupVisible: Bool = false

    private init() {
        // `SlashCommandStore.loadAll()` reads and JSON-decodes every custom
        // command file from disk. This type is `@MainActor`, so loading
        // synchronously in `init` runs that scan on the main thread — and the
        // first accessor is often `ManagementBadgeStore`'s periodic recompute
        // (counting commands) rather than a user opening the slash menu, which
        // tripped the app-hang watchdog. Load off the main actor and publish
        // back; `customCommands` stays empty for the few ms until it lands.
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                SlashCommandStore.loadAll()
            }.value
            self?.customCommands = loaded
        }
    }

    // MARK: - Refresh

    /// Reload from disk. Synchronous — callers are user-initiated CRUD on a
    /// small list, so the main-thread cost is negligible (unlike the cold
    /// first load, which `init` performs off the main actor).
    public func refresh() {
        customCommands = SlashCommandStore.loadAll()
    }

    // MARK: - CRUD

    @discardableResult
    public func create(
        name: String,
        description: String = "",
        icon: String = "text.bubble",
        template: String,
        pluginId: String? = nil
    ) -> SlashCommand {
        let cmd = SlashCommand(
            name: name,
            description: description,
            icon: icon,
            kind: .template,
            template: template,
            pluginId: pluginId
        )
        SlashCommandStore.save(cmd)
        refresh()
        return cmd
    }

    public func update(_ command: SlashCommand) {
        guard !command.isBuiltIn else { return }
        var updated = command
        updated.updatedAt = Date()
        SlashCommandStore.save(updated)
        refresh()
    }

    @discardableResult
    public func delete(id: UUID) -> Bool {
        let result = SlashCommandStore.delete(id: id)
        if result { refresh() }
        return result
    }

    /// Returns all persisted custom commands associated with a plugin.
    public func commands(forPluginId pluginId: String) -> [SlashCommand] {
        customCommands.filter { $0.pluginId == pluginId }
    }

    /// Delete every persisted custom command that belongs to a plugin.
    /// Returns the number of commands deleted.
    @discardableResult
    public func deleteByPluginId(_ pluginId: String) -> Int {
        let matches = commands(forPluginId: pluginId)
        guard !matches.isEmpty else { return 0 }
        var count = 0
        for cmd in matches where SlashCommandStore.delete(id: cmd.id) {
            count += 1
        }
        if count > 0 { refresh() }
        return count
    }

    // MARK: - Filtering

    /// Returns commands matching `query`, sorted by relevance then alphabetically.
    /// An empty query returns all commands in default order.
    public func filtered(query: String) -> [SlashCommand] {
        let all = allCommands
        guard !query.isEmpty else { return all }
        let q = query.lowercased()
        return
            all
            .compactMap { cmd -> (SlashCommand, Int)? in
                let score = matchScore(query: q, name: cmd.name.lowercased())
                return score > 0 ? (cmd, score) : nil
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
            }
            .map(\.0)
    }

    // MARK: - Private

    /// Full command list: built-ins → custom → skills (deduplicated by name).
    private var allCommands: [SlashCommand] {
        var seen = Set<String>()
        var result: [SlashCommand] = []

        func append(_ cmd: SlashCommand) {
            let key = cmd.name.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(cmd)
        }

        SlashCommand.builtIns.forEach(append)
        customCommands.forEach(append)

        // Surface enabled skills as template commands
        for skill in SkillManager.shared.skills where skill.enabled {
            let slug = skill.name
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            guard !slug.isEmpty else { continue }

            let desc =
                skill.description.isEmpty
                ? "Apply \(skill.name) skill"
                : skill.description

            append(
                SlashCommand(
                    id: skill.id,
                    name: slug,
                    description: desc,
                    icon: "wand.and.stars",
                    kind: .skill,
                    isBuiltIn: false
                )
            )
        }

        return result
    }

    /// Score: 3 = exact match, 2 = prefix match, 1 = substring match, 0 = no match.
    private func matchScore(query: String, name: String) -> Int {
        if name == query { return 3 }
        if name.hasPrefix(query) { return 2 }
        if name.contains(query) { return 1 }
        return 0
    }
}
