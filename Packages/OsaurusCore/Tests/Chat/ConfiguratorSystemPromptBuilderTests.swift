//
//  ConfiguratorSystemPromptBuilderTests.swift
//  OsaurusCoreTests
//
//  The Configurator's prompt carries the Osaurus knowledge the Orchestrator
//  used to: answer from the catalog and guide, the section roster, the
//  shared write contract, the install-vs-use split, and the dry-run rule.
//  These pins were moved from `DefaultAgentSystemPromptBuilderTests`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct ConfiguratorSystemPromptBuilderTests {

    private static let domains = [
        ConfigurationDomain(
            id: "config", displayName: "Config", summary: "Summary.", menuHint: "do / things",
            searchKeywords: [], exampleQueries: [], tools: [], writeToolNames: ["osaurus_config"])
    ]

    @Test
    func bothVariantsNameEveryRequiredTool() {
        for compact in [false, true] {
            let rendered = ConfiguratorSystemPromptBuilder._renderForTests(domains: Self.domains, compact: compact)
            for name in ConfiguratorSystemPromptBuilder.requiredToolNames {
                #expect(rendered.contains("`\(name)`"), "compact=\(compact) misses \(name)")
            }
        }
    }

    @Test
    func answersFromTheGuideNeverFromMemory() {
        for compact in [false, true] {
            let rendered = ConfiguratorSystemPromptBuilder._renderForTests(domains: Self.domains, compact: compact)
            #expect(rendered.contains("Never answer from memory"))
            #expect(rendered.contains("never name a Settings path that is not in the reference sections"))
            #expect(rendered.contains("quote its breadcrumb"))
        }
    }

    @Test
    func teachesTheWriteContractAndRoster() {
        for compact in [false, true] {
            let rendered = ConfiguratorSystemPromptBuilder._renderForTests(domains: Self.domains, compact: compact)
            #expect(rendered.contains(ConfigurationReadNextStep.writeContract))
            for section in ConfigSectionID.allNames {
                #expect(rendered.contains(section), "roster must name \(section)")
            }
            #expect(rendered.contains("configurator"))
            #expect(rendered.contains("changes NOTHING"))
            #expect(rendered.contains("ONLY after an apply result says applied"))
            #expect(rendered.contains("starts the download"))
            #expect(rendered.contains("default_agent.model"))
            #expect(rendered.contains("foundation"))
            #expect(rendered.contains("Settings-only"))
        }
    }

    @Test
    func actsInOneRequestWithoutChatConfirmation() {
        for compact in [false, true] {
            let rendered = ConfiguratorSystemPromptBuilder._renderForTests(domains: Self.domains, compact: compact)
            #expect(rendered.contains("approval card"))
            #expect(rendered.contains("never ask for confirmation"))
            #expect(rendered.contains("is one request: explain, then apply"))
            #expect(!rendered.contains("confirm each change"))
        }
    }

    @Test
    func neverDesignsWorkflowsOrNarratesToolCalls() {
        for compact in [false, true] {
            let rendered = ConfiguratorSystemPromptBuilder._renderForTests(domains: Self.domains, compact: compact)
            #expect(rendered.contains("Never design a new workflow"))
            #expect(rendered.contains("Never type a tool call"))
            #expect(rendered.contains("Never name your tools to the user"))
            #expect(rendered.contains("Keychain"))
            #expect(!rendered.contains("capabilities_load"))
            #expect(!rendered.contains("spawn_agent"))
            #expect(!rendered.contains("architect_handoff"))
        }
    }

    @Test
    func listsRegisteredWriteToolsAndAppendsInstructions() {
        let rendered = ConfiguratorSystemPromptBuilder._renderForTests(domains: Self.domains)
        #expect(rendered.contains("Change tools: `osaurus_config`."))
        ConfiguratorSystemPromptBuilder._resetForTests()
        defer { ConfiguratorSystemPromptBuilder._resetForTests() }
        let base = ConfiguratorSystemPromptBuilder.render(compact: false)
        let extended = ConfiguratorSystemPromptBuilder.render(compact: false, instructions: "  Be terse.  ")
        #expect(extended == base + "\n\nBe terse.")
        #expect(ConfiguratorSystemPromptBuilder.render(compact: false) == base)
    }

    @Test
    func agentCreation_draftsThroughTheDraftToolAndNeverCreates() {
        for compact in [false, true] {
            let rendered = ConfiguratorSystemPromptBuilder.renderAgentCreation(compact: compact)
            #expect(rendered.hasPrefix("# New Agent"))
            for required in ["agent_draft", "action: 'patch'", "action: 'tools'", "reasons", "kept_user_edits",
                "override_user_edits", "click Create", "created: true", "clarify"]
            {
                #expect(rendered.contains(required), "compact=\(compact) misses \(required)")
            }
            #expect(!rendered.contains("osaurus_config"), "a New Agent chat has no config writes")
        }
        #expect(
            ConfiguratorSystemPromptBuilder.renderAgentCreation(compact: true).count
                < ConfiguratorSystemPromptBuilder.renderAgentCreation(compact: false).count)
        let base = ConfiguratorSystemPromptBuilder.renderAgentCreation(compact: false)
        #expect(
            ConfiguratorSystemPromptBuilder.renderAgentCreation(compact: false, instructions: " Be warm. ")
                == base + "\n\nBe warm.")
    }
}
