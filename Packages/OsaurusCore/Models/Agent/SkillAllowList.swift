//
//  SkillAllowList.swift
//  osaurus
//
//  An agent's skill allow-list (`Agent.skillNames`) names skills the way
//  people and documents do: by display name or by Agent Skills slug. One
//  matcher serves the prompt manifest, `capabilities_load`, slash commands,
//  the editor and setup checks, so they cannot disagree about a skill.
//

import Foundation

extension Skill {
    /// Whether an allow-list entry names this skill: the display name
    /// (case-insensitive), or the slug of the name or of the on-disk folder.
    public func matchesAllowListEntry(_ entry: String) -> Bool {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if name.caseInsensitiveCompare(trimmed) == .orderedSame { return true }
        let slug = Skill.agentSkillsSlug(for: trimmed)
        guard !slug.isEmpty else { return false }
        return Skill.agentSkillsSlug(for: name) == slug || directoryName?.lowercased() == slug
    }
}

extension Agent {
    /// Whether this agent may see and load `skill`. No list means every skill.
    public func allowsSkill(_ skill: Skill) -> Bool {
        guard let skillNames else { return true }
        return skillNames.contains { skill.matchesAllowListEntry($0) }
    }

    /// Allow-list entries that name no skill in `skills`.
    public func missingAllowListedSkills(in skills: [Skill]) -> [String] {
        guard let skillNames else { return [] }
        return skillNames.filter { entry in !skills.contains { $0.matchesAllowListEntry(entry) } }
    }
}
