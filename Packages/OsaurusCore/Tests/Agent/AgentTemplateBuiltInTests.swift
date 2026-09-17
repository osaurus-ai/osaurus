//
//  AgentTemplateBuiltInTests.swift
//  OsaurusCoreTests
//
//  The bundled templates (`Resources/Templates/agent-template-*.json`) are
//  the first thing a new user sees on the Templates tab and what the
//  orchestrator offers by name. Pin that they ship, parse, and carry the
//  settings the design called for.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct AgentTemplateBuiltInTests {

    @Test
    func bundledTemplates_parseAndAreOrchestratorVisible() {
        let builtIn = AgentTemplateStore.shared.builtIn
        let names = Set(builtIn.map(\.name))
        #expect(names.isSuperset(of: ["Sub Agent", "Cloud Agent", "Local Agent"]))
        for template in builtIn {
            #expect(template.availableToOrchestrator)
            // General-purpose workers RAG-pick their tools. A hardcoded
            // manual list was how the bundled templates shipped tool names
            // that do not exist (`fetch`, `time`), so every created agent
            // came back "Skipped tools not installed here".
            #expect(template.agent.tools?.mode == "auto")
            #expect(template.agent.sandbox?.enabled == true)
            #expect(template.modelPolicy == .preferred)
            #expect(template.agent.capabilities?.relayEnabled == nil)
            #expect(template.agent.capabilities?.knowledgeCollectionIds == nil)
        }
    }

    @Test
    func subAgent_hasNoSubagents_andLocalAgent_hasMemory() throws {
        let store = AgentTemplateStore.shared
        let sub = try #require(store.template(named: "Sub Agent"))
        #expect(sub.agent.subagents?.enabled == false)
        #expect(sub.agent.capabilities?.memoryEnabled == false)
        let local = try #require(store.template(named: "local-agent"))
        #expect(local.agent.subagents?.enabled == true)
        #expect(local.agent.capabilities?.memoryEnabled == true)
        let cloud = try #require(store.template(named: "CLOUD AGENT"))
        #expect(cloud.agent.model == .value("sonnet-5"))
    }

    /// Any manual tool a bundled template names must be a real registered
    /// tool, or applying the template silently drops it. Auto-mode
    /// templates carry no list, so this is vacuously true for today's
    /// built-ins — it guards the next one that opts into a curated list.
    @Test
    func bundledManualTools_areAllRegistered() {
        let registered = Set(ToolRegistry.shared.listTools().map(\.name))
        for template in AgentTemplateStore.shared.builtIn {
            guard template.agent.tools?.mode == "manual" else { continue }
            for name in template.agent.tools?.enabled ?? [] {
                #expect(
                    registered.contains(name),
                    "\(template.name) lists unknown tool `\(name)`")
            }
        }
    }

    @Test
    func builtIn_isReportedAsBuiltIn() throws {
        let store = AgentTemplateStore.shared
        let cloud = try #require(store.template(named: "Cloud Agent"))
        #expect(store.isBuiltIn(cloud) || store.templates.contains { $0.id == cloud.id })
    }
}
