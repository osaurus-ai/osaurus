//
//  SkillCapabilityPolicyService.swift
//  osaurus
//
//  Read-only skill policy snapshots for the Skills management console.
//

import Foundation

enum SkillCapabilityPolicyService {
    struct Input: Sendable {
        let agentId: UUID
        let agentName: String
        let agentExists: Bool
        let isConfigurationAgent: Bool
        let toolMode: ToolSelectionMode
        let enabledSkillNames: Set<String>?
        let skills: [Skill]
        let indexSnapshot: SkillSearchIndexSnapshot

        init(
            agentId: UUID,
            agentName: String,
            agentExists: Bool = true,
            isConfigurationAgent: Bool = false,
            toolMode: ToolSelectionMode = .auto,
            enabledSkillNames: Set<String>? = nil,
            skills: [Skill],
            indexSnapshot: SkillSearchIndexSnapshot = .unavailable
        ) {
            self.agentId = agentId
            self.agentName = agentName
            self.agentExists = agentExists
            self.isConfigurationAgent = isConfigurationAgent
            self.toolMode = toolMode
            self.enabledSkillNames = enabledSkillNames
            self.skills = skills
            self.indexSnapshot = indexSnapshot
        }
    }

    @MainActor
    static func snapshot(agentId: UUID) async -> SkillCapabilityPolicyDiagnostic {
        let manager = AgentManager.shared
        let isConfigurationAgent = agentId == Agent.defaultId
        let agent = manager.agent(for: agentId) ?? (isConfigurationAgent ? Agent.default : nil)
        let skills = SkillManager.shared.skills
        let indexSnapshot = await SkillSearchService.shared.indexSnapshot()
        return build(
            Input(
                agentId: agentId,
                agentName: agent?.name ?? "Unknown agent",
                agentExists: agent != nil,
                isConfigurationAgent: isConfigurationAgent,
                toolMode: manager.effectiveToolSelectionMode(for: agentId),
                enabledSkillNames: manager.effectiveEnabledSkillNames(for: agentId).map(Set.init),
                skills: skills,
                indexSnapshot: indexSnapshot
            )
        )
    }

    static func build(_ input: Input) -> SkillCapabilityPolicyDiagnostic {
        let rows = input.skills
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            .map { row(for: $0, input: input) }

        return SkillCapabilityPolicyDiagnostic(
            agentId: input.agentId,
            agentName: input.agentName,
            toolMode: input.toolMode,
            agentScoped: input.enabledSkillNames != nil,
            vectorIndexInitialized: input.indexSnapshot.vectorIndexInitialized,
            vectorIndexAvailable: input.indexSnapshot.vectorIndexAvailable,
            usingLexicalFallback: input.indexSnapshot.usesLexicalFallback,
            knownSkillCount: input.indexSnapshot.knownSkillCount,
            totalSkillCount: input.skills.count,
            rows: rows
        )
    }

    private static func row(
        for skill: Skill,
        input: Input
    ) -> SkillCapabilityPolicyDiagnostic.Row {
        let source = source(for: skill)
        let agentAllowedByScope = input.enabledSkillNames?.contains(skill.name) ?? true
        let knownToSearchIndex =
            input.indexSnapshot.vectorIndexAvailable
            && input.indexSnapshot.knownSkillIds.contains(skill.id)

        var policyReasons: [SkillCapabilityPolicyReasonCode] = []
        var searchReasons: [SkillCapabilitySearchReasonCode] = []

        func appendPolicy(_ reason: SkillCapabilityPolicyReasonCode) {
            if !policyReasons.contains(reason) { policyReasons.append(reason) }
        }
        func appendSearch(_ reason: SkillCapabilitySearchReasonCode) {
            if !searchReasons.contains(reason) { searchReasons.append(reason) }
        }

        let state: SkillCapabilityState
        let agentAllowed: Bool
        if !input.agentExists {
            state = .unavailable
            agentAllowed = false
            appendPolicy(.agentNotFound)
            appendSearch(.agentNotFound)
        } else if input.isConfigurationAgent {
            state = .hidden
            agentAllowed = false
            appendPolicy(.configurationAgentUnsupported)
            appendSearch(.configurationAgentUnsupported)
        } else if !skill.enabled {
            state = .disabled
            agentAllowed = agentAllowedByScope
            appendPolicy(.globallyDisabled)
            appendSearch(.globallyDisabled)
        } else if !agentAllowedByScope {
            state = .hidden
            agentAllowed = false
            appendPolicy(.hiddenByAgentScope)
            appendSearch(.hiddenByAgentScope)
        } else {
            state = .loadable
            agentAllowed = true
            appendPolicy(.loadableViaCapabilitiesLoad)
            if input.enabledSkillNames == nil {
                appendPolicy(.unscopedLegacyAgent)
            } else {
                appendPolicy(.allowedByAgentScope)
            }
        }

        let searchable: Bool
        if state == .loadable {
            if input.indexSnapshot.vectorIndexAvailable {
                if knownToSearchIndex {
                    appendSearch(.searchable)
                    appendSearch(.knownToSearchIndex)
                    searchable = true
                } else {
                    appendSearch(.notKnownToSearchIndex)
                    searchable = false
                }
            } else {
                appendSearch(.searchable)
                appendSearch(.lexicalFallback)
                appendSearch(.vectorIndexUnavailable)
                searchable = true
            }
        } else {
            searchable = false
            if input.indexSnapshot.vectorIndexAvailable {
                if knownToSearchIndex {
                    appendSearch(.knownToSearchIndex)
                } else {
                    appendSearch(.notKnownToSearchIndex)
                }
            } else {
                appendSearch(.vectorIndexUnavailable)
            }
        }

        return SkillCapabilityPolicyDiagnostic.Row(
            skillId: skill.id,
            skillName: skill.name,
            description: skill.description,
            source: source,
            state: state,
            loadId: "skill/\(skill.name)",
            pluginId: skill.pluginId,
            globallyEnabled: skill.enabled,
            agentAllowed: agentAllowed,
            agentScoped: input.enabledSkillNames != nil,
            knownToSearchIndex: knownToSearchIndex,
            searchableByCapabilitiesDiscover: searchable,
            policyReasonCodes: policyReasons,
            searchReasonCodes: searchReasons,
            instructionCharacters: skill.instructions.count
        )
    }

    private static func source(for skill: Skill) -> SkillCapabilitySource {
        if skill.isBuiltIn { return .builtIn }
        if skill.pluginId != nil { return .plugin }
        return .standalone
    }
}
