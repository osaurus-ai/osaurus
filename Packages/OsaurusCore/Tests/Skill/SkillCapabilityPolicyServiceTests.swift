//
//  SkillCapabilityPolicyServiceTests.swift
//  osaurus
//
//  Focused tests for read-only skill capability policy/status diagnostics.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SkillCapabilityPolicyServiceTests {

    @Test func scopedEnabledSkillIsLoadableAndSearchableWhenKnownToSearchIndex() {
        let skill = makeSkill(
            name: "Research Helper",
            description: "Structured research",
            enabled: true
        )
        let diagnostic = SkillCapabilityPolicyService.build(
            .init(
                agentId: UUID(),
                agentName: "Research Agent",
                enabledSkillNames: [skill.name],
                skills: [skill],
                indexSnapshot: .init(
                    vectorIndexInitialized: true,
                    vectorIndexAvailable: true,
                    knownSkillIds: [skill.id]
                )
            )
        )

        let row = diagnostic.rows[0]
        #expect(diagnostic.agentScoped)
        #expect(diagnostic.vectorIndexAvailable)
        #expect(row.state == .loadable)
        #expect(row.source == .standalone)
        #expect(row.loadId == "skill/Research Helper")
        #expect(row.agentAllowed)
        #expect(row.knownToSearchIndex)
        #expect(row.searchableByCapabilitiesDiscover)
        #expect(row.policyReasonCodes == [.loadableViaCapabilitiesLoad, .allowedByAgentScope])
        #expect(row.searchReasonCodes == [.searchable, .knownToSearchIndex])
    }

    @Test func disabledSkillExplainsGlobalDisableBeforeIndexingStatus() {
        let skill = makeSkill(
            name: "Disabled Skill",
            enabled: false,
            pluginId: "com.example.plugin"
        )
        let diagnostic = SkillCapabilityPolicyService.build(
            .init(
                agentId: UUID(),
                agentName: "Agent",
                enabledSkillNames: [skill.name],
                skills: [skill],
                indexSnapshot: .init(
                    vectorIndexInitialized: true,
                    vectorIndexAvailable: true,
                    knownSkillIds: [skill.id]
                )
            )
        )

        let row = diagnostic.rows[0]
        #expect(row.source == .plugin)
        #expect(row.state == .disabled)
        #expect(row.globallyEnabled == false)
        #expect(row.agentAllowed)
        #expect(row.searchableByCapabilitiesDiscover == false)
        #expect(row.policyReasonCodes.contains(.globallyDisabled))
        #expect(row.searchReasonCodes.contains(.globallyDisabled))
        #expect(row.searchReasonCodes.contains(.knownToSearchIndex))
    }

    @Test func agentScopeHidesEnabledSkillOutsideGrant() {
        let skill = makeSkill(name: "Hidden Skill", enabled: true)
        let diagnostic = SkillCapabilityPolicyService.build(
            .init(
                agentId: UUID(),
                agentName: "Agent",
                enabledSkillNames: [],
                skills: [skill],
                indexSnapshot: .init(
                    vectorIndexInitialized: true,
                    vectorIndexAvailable: true,
                    knownSkillIds: [skill.id]
                )
            )
        )

        let row = diagnostic.rows[0]
        #expect(row.state == .hidden)
        #expect(row.agentAllowed == false)
        #expect(row.searchableByCapabilitiesDiscover == false)
        #expect(row.policyReasonCodes == [.hiddenByAgentScope])
        #expect(row.searchReasonCodes.contains(.hiddenByAgentScope))
        #expect(row.searchReasonCodes.contains(.knownToSearchIndex))
    }

    @Test func loadableSkillExplainsWhenVectorIndexDoesNotKnowIt() {
        let skill = makeSkill(name: "Unindexed Skill", enabled: true)
        let diagnostic = SkillCapabilityPolicyService.build(
            .init(
                agentId: UUID(),
                agentName: "Agent",
                enabledSkillNames: [skill.name],
                skills: [skill],
                indexSnapshot: .init(
                    vectorIndexInitialized: true,
                    vectorIndexAvailable: true,
                    knownSkillIds: []
                )
            )
        )

        let row = diagnostic.rows[0]
        #expect(row.state == .loadable)
        #expect(row.knownToSearchIndex == false)
        #expect(row.searchableByCapabilitiesDiscover == false)
        #expect(row.searchReasonCodes == [.notKnownToSearchIndex])
    }

    @Test func unseededAgentReportsLegacyScopeAndLexicalFallback() {
        let skill = makeSkill(name: "Legacy Skill", enabled: true)
        let diagnostic = SkillCapabilityPolicyService.build(
            .init(
                agentId: UUID(),
                agentName: "Legacy Agent",
                enabledSkillNames: nil,
                skills: [skill],
                indexSnapshot: .unavailable
            )
        )

        let row = diagnostic.rows[0]
        #expect(diagnostic.agentScoped == false)
        #expect(diagnostic.usingLexicalFallback)
        #expect(row.state == .loadable)
        #expect(row.agentAllowed)
        #expect(row.knownToSearchIndex == false)
        #expect(row.searchableByCapabilitiesDiscover)
        #expect(row.policyReasonCodes.contains(.unscopedLegacyAgent))
        #expect(row.searchReasonCodes == [.searchable, .lexicalFallback, .vectorIndexUnavailable])
    }

    @Test func configurationAgentReportsSkillLoadingUnsupported() {
        let skill = makeSkill(name: "Config Hidden", enabled: true)
        let diagnostic = SkillCapabilityPolicyService.build(
            .init(
                agentId: Agent.defaultId,
                agentName: "Osaurus",
                isConfigurationAgent: true,
                enabledSkillNames: [skill.name],
                skills: [skill],
                indexSnapshot: .unavailable
            )
        )

        let row = diagnostic.rows[0]
        #expect(row.state == .hidden)
        #expect(row.agentAllowed == false)
        #expect(row.searchableByCapabilitiesDiscover == false)
        #expect(row.policyReasonCodes == [.configurationAgentUnsupported])
        #expect(row.searchReasonCodes.contains(.configurationAgentUnsupported))
    }

    @Test func missingAgentReportsUnavailableForAllSkills() {
        let skill = makeSkill(name: "Missing Agent Skill", enabled: true)
        let diagnostic = SkillCapabilityPolicyService.build(
            .init(
                agentId: UUID(),
                agentName: "Unknown agent",
                agentExists: false,
                enabledSkillNames: [skill.name],
                skills: [skill],
                indexSnapshot: .unavailable
            )
        )

        let row = diagnostic.rows[0]
        #expect(row.state == .unavailable)
        #expect(row.agentAllowed == false)
        #expect(row.searchableByCapabilitiesDiscover == false)
        #expect(row.policyReasonCodes == [.agentNotFound])
        #expect(row.searchReasonCodes.contains(.agentNotFound))
    }

    @Test func reporterSafeMarkdownOmitsInstructionsAndPluginPaths() {
        let skill = makeSkill(
            name: "Reporter Skill",
            description: "Short description",
            instructions: "Never leak this instruction body.",
            pluginId: "com.example.plugin"
        )
        let diagnostic = SkillCapabilityPolicyService.build(
            .init(
                agentId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                agentName: "Reporter Agent",
                enabledSkillNames: [skill.name],
                skills: [skill],
                indexSnapshot: .unavailable
            )
        )

        let report = diagnostic.reporterSafeMarkdown(
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000)
        )

        #expect(report.contains("# Skill Policy Report"))
        #expect(report.contains("Reporter Skill"))
        #expect(report.contains("Reporter-safe fields only"))
        #expect(!report.contains("Never leak this instruction body."))
        #expect(!report.contains("SKILL.md"))
        #expect(!report.contains("references/"))
    }

    @Test func reporterSafeMarkdownEscapesTableSpecialCharacters() {
        let skill = makeSkill(
            name: "Pipe | Skill\nName",
            description: "Short description",
            instructions: "instructions"
        )
        let diagnostic = SkillCapabilityPolicyService.build(
            .init(
                agentId: UUID(),
                agentName: "Reporter | Agent",
                enabledSkillNames: [skill.name],
                skills: [skill],
                indexSnapshot: .unavailable
            )
        )

        let report = diagnostic.reporterSafeMarkdown()

        #expect(report.contains("Pipe \\| Skill Name"))
        #expect(report.contains("Reporter \\| Agent"))
        #expect(!report.contains("Pipe | Skill\nName"))
    }

    private func makeSkill(
        name: String,
        description: String = "fixture",
        instructions: String = "instructions",
        enabled: Bool = true,
        isBuiltIn: Bool = false,
        pluginId: String? = nil
    ) -> Skill {
        Skill(
            id: UUID(),
            name: name,
            description: description,
            version: "1.0.0",
            keywords: [],
            enabled: enabled,
            instructions: instructions,
            isBuiltIn: isBuiltIn,
            pluginId: pluginId
        )
    }
}
