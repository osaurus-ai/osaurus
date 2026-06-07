//
//  SkillSuggestions.swift
//  osaurus
//
//  Query-relevance ranking for standalone (non-plugin) skills. The ranked
//  result is folded into the enabled-capabilities manifest as its trailing
//  "Skills (no plugin)" group, so a standalone skill the user asks about is
//  grounded even when it isn't loaded into the schema. The model pulls any
//  skill it wants via `capabilities_load` — no schema inflation, no extra
//  round-trip in the common case.
//
//  Plugin-bundled skills are NOT handled here; they ride in the manifest's
//  per-plugin groups alongside their sibling tools (see
//  `SystemPromptComposer.deriveEnabledManifest`).
//

import Foundation

// MARK: - Data

/// One standalone skill the model can pull in via
/// `capabilities_load("skill/<name>")`. Only carries the surface
/// description — the full instructions remain in `SkillManager` and load
/// on demand, keeping the system prompt small.
struct SkillTeaser: Equatable, Sendable {
    let name: String
    let description: String
}

// MARK: - Ranking

enum SkillSuggestions {

    /// Hard cap on standalone skill teasers per turn. Three keeps the
    /// trailing manifest group compact and matches what
    /// `CapabilitiesDiscoverTool` already returns for `topK.skills` in its
    /// hit shape.
    static let maxSkillSuggestions: Int = 3

    /// Embedding-search candidate pool. We over-fetch so post-filtering
    /// (plugin-bundled, already-loaded) can still surface the top
    /// `maxSkillSuggestions` standalone skills.
    private static let skillSearchCandidatePool: Int = 12

    /// Build a compact list of standalone skill teasers that semantically
    /// match `query`. "Standalone" means **not bundled with a plugin** —
    /// plugin skills are surfaced via the manifest's per-plugin groups, and
    /// showing them twice would be noise.
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
}
