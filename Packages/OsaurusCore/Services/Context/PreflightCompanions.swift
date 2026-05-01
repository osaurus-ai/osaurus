//
//  PreflightCompanions.swift
//  osaurus
//
//  Phase-2 preflight: when the LLM picks a tool that belongs to a plugin
//  (e.g. `browser_navigate` from `osaurus.browser`), surface the plugin's
//  *other* enabled tools and bundled skill as a compact teaser. The model
//  loads anything it needs via the existing `capabilities_load` tool — no
//  new ABI, no schema inflation, no extra round-trip in the common case.
//
//  The single biggest under-use of plugins today is that the model gets
//  one tool from a cohesive plugin and never learns that the rest exist.
//  This file fixes that by deriving + rendering the companion section.
//

import Foundation

// MARK: - Data

/// One sibling tool from the same plugin as a picked tool. Mirrors only
/// the fields needed to render the teaser line — the full `Tool` spec is
/// re-resolved from `ToolRegistry` if/when the model calls
/// `capabilities_load`.
struct ToolTeaser: Equatable, Sendable {
    let name: String
    let description: String
}

/// One plugin-bundled skill the model can pull in via
/// `capabilities_load("skill/<name>")`. Only carries the surface
/// description — the full instructions remain in `SkillManager` and load
/// on demand, keeping the system prompt small.
struct SkillTeaser: Equatable, Sendable {
    let name: String
    let description: String
}

/// All companion capabilities (siblings + skill) attached to one plugin
/// that contributed at least one tool to this turn's preflight selection.
/// Empty when both `siblingTools` and `skill` would be empty — the
/// derivation step skips those plugins entirely.
struct PluginCompanion: Equatable, Sendable {
    /// Provider/group identifier from `ToolRegistry.groupName(for:)`.
    /// For native plugins this matches `PluginManifest.plugin_id`
    /// (e.g. `osaurus.browser`); for MCP it's the provider name; for
    /// sandbox plugins it's the sandbox plugin id.
    let pluginId: String
    /// Friendly name for prompt rendering. Falls back to `pluginId` when
    /// no display name is available (MCP / sandbox plugins).
    let pluginDisplay: String
    /// `nil` when the plugin ships no enabled skill. The teaser still
    /// renders if `siblingTools` is non-empty.
    let skill: SkillTeaser?
    /// Already deduped against picked tools, deterministically ordered,
    /// and capped (see `PreflightCompanions.maxSiblingTools`).
    let siblingTools: [ToolTeaser]
}

// MARK: - Derivation

enum PreflightCompanions {

    /// Hard cap on sibling tools rendered per plugin. Big plugins (the
    /// browser plugin ships ~22 tools) would otherwise blow the prompt
    /// budget. The model can always run `capabilities_search` for more.
    static let maxSiblingTools: Int = 6

    /// Build the companion list from a finalized preflight selection.
    /// MUST run on the main actor — touches `ToolRegistry`, `SkillManager`
    /// and `PluginManager`, which are all main-actor-isolated.
    @MainActor
    static func derive(
        selectedNames: [String],
        query: String
    ) -> [PluginCompanion] {
        guard !selectedNames.isEmpty else { return [] }

        // Bucket picks by their plugin/provider group. Tools without a
        // group (built-in / runtime-managed) carry no companion notion
        // and are dropped here.
        var pluginIds: [String] = []
        var seenPluginIds: Set<String> = []
        for name in selectedNames {
            guard let group = ToolRegistry.shared.groupName(for: name),
                !group.isEmpty
            else { continue }
            if seenPluginIds.insert(group).inserted {
                pluginIds.append(group)
            }
        }
        guard !pluginIds.isEmpty else { return [] }

        let pickedSet = Set(selectedNames)
        let allDynamic = ToolRegistry.shared.listDynamicTools()
        // Pre-bucket dynamic tools by group in one pass so we don't walk
        // the catalog once per picked plugin.
        var byGroup: [String: [ToolRegistry.ToolEntry]] = [:]
        for entry in allDynamic {
            guard let group = ToolRegistry.shared.groupName(for: entry.name),
                !group.isEmpty
            else { continue }
            byGroup[group, default: []].append(entry)
        }

        var companions: [PluginCompanion] = []
        companions.reserveCapacity(pluginIds.count)

        for pluginId in pluginIds {
            let display = pluginDisplayName(for: pluginId)
            let siblingsRaw = (byGroup[pluginId] ?? []).filter { !pickedSet.contains($0.name) }
            let siblings = selectSiblings(from: siblingsRaw, query: query)
            let skill = pluginSkillTeaser(for: pluginId)

            // Skip plugins where there's literally nothing to surface. A
            // plugin with one tool, no sibling, no skill contributes only
            // noise to the prompt.
            if siblings.isEmpty, skill == nil { continue }

            companions.append(
                PluginCompanion(
                    pluginId: pluginId,
                    pluginDisplay: display,
                    skill: skill,
                    siblingTools: siblings
                )
            )
        }

        return companions
    }

    /// Score-then-cap sibling tools. Scoring is intentionally cheap (word
    /// overlap with the query) — embeddings are an optional dependency
    /// throughout preflight and we don't want to add a second async hop
    /// just to order a teaser. Final ordering is alphabetical so two
    /// equally-scored tools render in a deterministic, KV-cache-stable
    /// order across runs.
    static func selectSiblings(
        from candidates: [ToolRegistry.ToolEntry],
        query: String
    ) -> [ToolTeaser] {
        guard !candidates.isEmpty else { return [] }
        let queryTokens = tokenize(query)

        let scored: [(entry: ToolRegistry.ToolEntry, score: Int)] = candidates.map { entry in
            let haystack = tokenize("\(entry.name) \(entry.description)")
            // Count overlap with the query so e.g. "log in to amazon" lifts
            // `browser_open_login` ahead of `browser_set_user_agent`.
            let overlap = queryTokens.intersection(haystack).count
            return (entry, overlap)
        }

        let topByScore =
            scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.entry.name < rhs.entry.name
            }
            .prefix(maxSiblingTools)

        // Re-sort the kept slice alphabetically so prompt rendering is
        // byte-stable independent of dictionary ordering inside the
        // catalog source.
        return
            topByScore
            .map { ToolTeaser(name: $0.entry.name, description: $0.entry.description) }
            .sorted { $0.name < $1.name }
    }

    /// Lowercase-alphanumeric word split. Strips punctuation so a query
    /// like "amazon-orders?" still tokenises to ["amazon", "orders"].
    static func tokenize(_ text: String) -> Set<String> {
        let lowered = text.lowercased()
        let pieces = lowered.split { !$0.isLetter && !$0.isNumber }
        var tokens: Set<String> = []
        for piece in pieces {
            // Single-char tokens are noise (a, e, i, etc.) and drag the
            // overlap score around without adding signal.
            guard piece.count >= 2 else { continue }
            tokens.insert(String(piece))
        }
        return tokens
    }

    @MainActor
    private static func pluginSkillTeaser(for pluginId: String) -> SkillTeaser? {
        let skills = SkillManager.shared.pluginSkills(for: pluginId)
        guard let skill = skills.first(where: { $0.enabled }) else { return nil }
        return SkillTeaser(name: skill.name, description: skill.description)
    }

    /// Friendly plugin name for the rendered teaser. Native plugins carry
    /// a `name` in their manifest (e.g. "Browser"); MCP/sandbox-plugin
    /// groups don't — we fall back to the raw id so the section still
    /// renders something sensible.
    @MainActor
    private static func pluginDisplayName(for pluginId: String) -> String {
        if let loaded = PluginManager.shared.loadedPlugin(for: pluginId),
            let display = loaded.plugin.manifest.name,
            !display.isEmpty
        {
            return display
        }
        return pluginId
    }

    // MARK: - Rendering

    /// Render the "Plugin Companions" prompt section. Returns `nil` when
    /// `companions` is empty so callers can skip appending an empty
    /// section. Skill lines come before sibling tools in each block —
    /// the trailing nudge tells the model to load the skill first since
    /// the skill explains when each sibling tool is appropriate.
    static func render(_ companions: [PluginCompanion]) -> String? {
        guard !companions.isEmpty else { return nil }
        let body = companions.map(renderBlock).joined(separator: "\n\n")
        return """
            ## Plugin Companions

            \(body)

            \(usageNudge)
            """
    }

    /// Render one plugin's block: header line + skill line (if any) +
    /// sibling tool lines. Pulled out of `render` so the section/body
    /// composition reads as a one-liner.
    private static func renderBlock(_ companion: PluginCompanion) -> String {
        var lines: [String] = [
            "You loaded tools from the **\(companion.pluginDisplay)** plugin. "
                + "These companions exist but are NOT in your schema — pull only what you need:"
        ]
        if let skill = companion.skill {
            let desc = skill.description.isEmpty ? "Plugin skill." : skill.description
            lines.append("- `skill/\(skill.name)` — \(desc)")
        }
        for tool in companion.siblingTools {
            let desc = tool.description.isEmpty ? "(no description)" : tool.description
            lines.append("- `tool/\(tool.name)` — \(desc)")
        }
        return lines.joined(separator: "\n")
    }

    /// Trailing instructions appended once per section. The one-shot +
    /// call-by-name lines exist because reasoning models (Qwen3.x, etc.)
    /// otherwise treat `capabilities_load` as the action itself and
    /// re-load the same id every turn instead of calling the now-available
    /// tool. See `renderNudgeWarnsAgainstReLoadingAndExplainsCallByName`
    /// for the regression pin.
    private static let usageNudge = """
        How to use this section:
        - Load: `capabilities_load({"ids": ["skill/<name>", "tool/<name>"]})`. Batch ids you'll need together in one call.
        - Order: load the skill first when one is listed — it explains when each sibling tool is appropriate.
        - One-shot: a successful `capabilities_load` adds the tool/skill to your schema for the rest of the conversation. Do NOT call `capabilities_load` again for an id you've already loaded.
        - Use: after loading, call the tool directly by its name (e.g. `browser_open_login(...)`) just like any tool you already had — there is no separate "activate" step.
        """

    // MARK: - Skill Suggestions

    /// Hard cap on standalone skill teasers per turn. Three keeps the
    /// section visually compact and matches what `CapabilitiesSearchTool`
    /// already returns for `topK.skills` in its hit shape.
    static let maxSkillSuggestions: Int = 3

    /// Embedding-search candidate pool. We over-fetch so post-filtering
    /// (plugin-bundled, already-loaded) can still surface the top
    /// `maxSkillSuggestions` standalone skills.
    private static let skillSearchCandidatePool: Int = 12

    /// Build a compact list of standalone skill teasers that semantically
    /// match `query`. "Standalone" means **not bundled with a plugin** —
    /// plugin skills are surfaced via the existing `derive(...)` path
    /// when one of their plugin's tools is picked, and showing them
    /// twice (once as a companion, once as a suggestion) is noise.
    ///
    /// Skills that already appear in `alreadyLoadedSkillNames` are
    /// filtered out so re-loading prompts disappear after the first
    /// `capabilities_load`.
    ///
    /// Returns at most `maxSkillSuggestions` teasers ordered by search
    /// score, with alphabetical tie-break so prompt rendering is byte
    /// stable when two skills tie.
    static func deriveSkillSuggestions(
        query: String,
        alreadyLoadedSkillNames: Set<String> = []
    ) async -> [SkillTeaser] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let hits = await SkillSearchService.shared.search(
            query: trimmed,
            topK: skillSearchCandidatePool
        )
        return rankSkillSuggestions(
            from: hits,
            alreadyLoadedSkillNames: alreadyLoadedSkillNames
        )
    }

    /// Pure post-search filter + sort + cap. Pulled out of
    /// `deriveSkillSuggestions` so the ordering rules (plugin
    /// exclusion, already-loaded suppression, score desc with
    /// alphabetical tie-break, max-3 cap) can be unit-tested without
    /// spinning up VecturaKit.
    static func rankSkillSuggestions(
        from hits: [SkillSearchResult],
        alreadyLoadedSkillNames: Set<String>
    ) -> [SkillTeaser] {
        let standalone = hits.filter { hit in
            hit.skill.pluginId == nil
                && !alreadyLoadedSkillNames.contains(hit.skill.name)
        }
        guard !standalone.isEmpty else { return [] }

        // Sort by score desc, alphabetical on ties. The search service
        // already orders by score but does not break ties deterministically.
        let ordered = standalone.sorted { lhs, rhs in
            if lhs.searchScore != rhs.searchScore {
                return lhs.searchScore > rhs.searchScore
            }
            return lhs.skill.name < rhs.skill.name
        }

        return Array(ordered.prefix(maxSkillSuggestions))
            .map { SkillTeaser(name: $0.skill.name, description: $0.skill.description) }
    }

    /// Render the `## Skill Suggestions` prompt section. Returns `nil`
    /// when `teasers` is empty so callers can skip appending an empty
    /// block. Reuses `usageNudge` so the loader story the model reads
    /// is identical across companions and suggestions.
    static func renderSkillSuggestions(_ teasers: [SkillTeaser]) -> String? {
        guard !teasers.isEmpty else { return nil }
        var lines: [String] = [
            "These skills semantically match the user's request. They are NOT in your schema — pull only what you'll actually use:"
        ]
        for skill in teasers {
            let desc = skill.description.isEmpty ? "(no description)" : skill.description
            lines.append("- `skill/\(skill.name)` — \(desc)")
        }
        let body = lines.joined(separator: "\n")
        return """
            ## Skill Suggestions

            \(body)

            \(usageNudge)
            """
    }
}
