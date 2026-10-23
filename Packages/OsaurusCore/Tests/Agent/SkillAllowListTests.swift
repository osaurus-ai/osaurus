//
//  SkillAllowListTests.swift
//  OsaurusCoreTests
//
//  Pins the per-agent skill allow-list: how entries match skills, how the
//  `agents[].skills` key round-trips through the document (absent / null /
//  list), what templates derive from it, and the setup advisory for
//  skills that are not installed.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct SkillAllowListTests {

    private let triage = Skill(name: "Triage Ticket", directoryName: "triage-ticket")
    private let review = Skill(name: "Code Review")

    @Test
    func entriesMatchByNameOrSlug() {
        #expect(triage.matchesAllowListEntry("Triage Ticket"))
        #expect(triage.matchesAllowListEntry("triage ticket"))
        #expect(triage.matchesAllowListEntry("triage-ticket"))
        #expect(!triage.matchesAllowListEntry("triage"))
        #expect(!triage.matchesAllowListEntry("  "))
        #expect(review.matchesAllowListEntry("code-review"))
    }

    @Test
    func builtInSkillsMatchTheirEnglishSlugInEveryLanguage() throws {
        let researcher = try #require(Skill.builtInSkills.first { $0.directoryName == "web-researcher" })
        let localized = Skill(
            id: researcher.id, name: "Investigador web", isBuiltIn: true,
            directoryName: researcher.directoryName)
        #expect(localized.matchesAllowListEntry("web-researcher"))
        for skill in Skill.builtInSkills {
            let slug = try #require(skill.directoryName)
            #expect(slug == Skill.agentSkillsSlug(for: slug), "\(slug) is not a slug")
        }
        #expect(Set(Skill.builtInSkills.compactMap(\.directoryName)).count == Skill.builtInSkills.count)
    }

    @Test
    func noListAllowsEverySkill_emptyListAllowsNone() {
        var agent = AgentManager.newCustomAgentRecord(name: "Probe")
        #expect(agent.allowsSkill(triage))
        agent.skillNames = []
        #expect(!agent.allowsSkill(triage))
        agent.skillNames = ["triage-ticket"]
        #expect(agent.allowsSkill(triage))
        #expect(!agent.allowsSkill(review))
        #expect(agent.missingAllowListedSkills(in: [triage, review]).isEmpty)
        agent.skillNames = ["triage-ticket", "billing-lookup"]
        #expect(agent.missingAllowListedSkills(in: [triage, review]) == ["billing-lookup"])
    }

    @Test
    func agentPersistsSkillNames_andOldRecordsDecodeAsNoList() throws {
        var agent = AgentManager.newCustomAgentRecord(name: "Probe")
        agent.skillNames = ["triage-ticket"]
        let data = try JSONEncoder().encode(agent)
        let decoded = try JSONDecoder().decode(Agent.self, from: data)
        #expect(decoded.skillNames == ["triage-ticket"])

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "skillNames")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Agent.self, from: legacy).skillNames == nil)
    }

    @Test
    func documentKeyDistinguishesAbsentNullAndList() throws {
        let doc = try ConfigYAML.decode(
            """
            version: 1
            agents:
              - name: A
                skills: [triage-ticket, Code Review]
              - name: B
                skills: null
              - name: C
                skills: []
              - name: D
            """)
        let agents = try #require(doc.agents)
        #expect(agents[0].skills == .value(["triage-ticket", "Code Review"]))
        #expect(agents[1].skills == .null)
        #expect(agents[2].skills == .value([]))
        #expect(agents[3].skills == .absent)

        let reparsed = try ConfigYAML.decode(try ConfigYAML.encode(doc))
        #expect(reparsed.agents?.map(\.skills) == agents.map(\.skills))
    }

    @Test
    func templateRequirementsCarryTheAllowList_andToolsExclusionDropsIt() {
        var entry = AgentEntry(name: "Support Desk")
        entry.skills = .value(["triage-ticket"])
        let template = AgentTemplate(name: "Support Desk", agent: entry)
        #expect(template.derivedRequirements().skills == ["triage-ticket"])
        #expect(template.derivedRequirements().items.contains { $0.kind == .skill && $0.value == "triage-ticket" })

        let trimmed = template.excluding([.tools])
        #expect(trimmed.agent.skills == .absent)
        #expect(trimmed.requirements.skills.isEmpty)
    }

    @Test
    func requirementsWithoutSkillsKeepTheirEncoding() throws {
        let data = try JSONEncoder().encode(TemplateRequirements())
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("skills"))
    }

    @Test
    func setupCheckerFlagsAllowListedSkillsThatAreNotInstalled() {
        var agent = AgentManager.newCustomAgentRecord(name: "Probe")
        agent.skillNames = ["triage-ticket", "billing-lookup"]
        let env = SetupChecker.Environment(
            registeredToolNames: [],
            modelCatalog: ConfigModelReference.Catalog(localModelIds: [], providers: []),
            isPermissionGranted: { _ in true },
            bookmarkResolves: { _ in true },
            knowledgeCollectionExists: { _ in true },
            installedSkills: [triage])
        let report = SetupChecker.check(agent, environment: env)
        #expect(report.items.count == 1)
        #expect(report.items.first?.kind == .skill)
        #expect(report.items.first?.severity == .advisory)
        #expect(report.items.first?.value == "billing-lookup")
    }
}
