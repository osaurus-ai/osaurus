//
//  SystemPromptInjectionTraceTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("System prompt injection source trace")
@MainActor
struct SystemPromptInjectionTraceTests {
    @Test("custom agent prompt lands in persona and static prefix")
    func customAgentPromptLandsInPersonaStaticPrefix() {
        let expectedPrompt = "TRACE-SYSTEM-PROMPT-\(UUID().uuidString): answer as Gerald"
        let agentId = UUID()
        let snapshot = AgentConfigSnapshot(
            agentId: agentId,
            toolsDisabled: false,
            memoryDisabled: true,
            autonomousConfig: nil,
            toolMode: .auto,
            model: nil,
            manualToolNames: nil,
            systemPrompt: expectedPrompt,
            dbEnabled: false
        )
        let composer = SystemPromptComposer.forChat(
            snapshot: snapshot,
            agentId: agentId,
            executionMode: .none
        )
        let manifest = composer.manifest()
        let trace = manifest.systemPromptInjectionTrace(
            expectedPrompt: expectedPrompt,
            renderedPrompt: composer.render()
        )

        #expect(manifest.section(PromptSectionID.persona)?.content.contains(expectedPrompt) == true)
        #expect(trace.passed)
        #expect(trace.personaSectionContainsExpectedPrompt)
        #expect(trace.staticPrefixContainsExpectedPrompt)
        #expect(trace.renderedPromptContainsExpectedPrompt)
        #expect(!trace.memorySectionContainsExpectedPrompt)
        #expect(trace.reasonCodes.contains("present_in_persona_section"))
    }

    @Test("convenience trace overload uses composer render contract")
    func convenienceTraceUsesComposerRenderContract() {
        let expectedPrompt = "TRACE-RENDER-PATH-\(UUID().uuidString)"
        var composer = SystemPromptComposer()
        composer.append(.static(id: PromptSectionID.platform, label: "Platform", content: "platform"))
        composer.append(.static(id: PromptSectionID.persona, label: "Persona", content: "\n\(expectedPrompt)\n"))

        let explicitTrace = composer.manifest().systemPromptInjectionTrace(
            expectedPrompt: expectedPrompt,
            renderedPrompt: composer.render()
        )
        let convenienceTrace = composer.manifest().systemPromptInjectionTrace(expectedPrompt: expectedPrompt)

        #expect(convenienceTrace == explicitTrace)
        #expect(convenienceTrace.passed)
    }

    @Test("memory-only prompt match does not prove system injection")
    func memoryOnlyPromptMatchDoesNotPass() {
        let expectedPrompt = "TRACE-MEMORY-ONLY-\(UUID().uuidString)"
        var composer = SystemPromptComposer()
        composer.append(
            .dynamic(
                id: PromptSectionID.memory,
                label: "Memory",
                content: "Remember this test sentinel: \(expectedPrompt)"
            )
        )
        let trace = composer.manifest().systemPromptInjectionTrace(
            expectedPrompt: expectedPrompt,
            renderedPrompt: composer.render()
        )

        #expect(!trace.passed)
        #expect(trace.memorySectionContainsExpectedPrompt)
        #expect(!trace.staticPrefixContainsExpectedPrompt)
        #expect(!trace.personaSectionContainsExpectedPrompt)
    }
}
