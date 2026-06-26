// Copyright 2026 Osaurus AI. All rights reserved.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Runtime proof validation")
struct RuntimeProofValidationTests {
    @Test("complete visible text row can be marked proven")
    func completeVisibleRowIsAcceptable() {
        let row = RuntimeProofRow(
            modelId: "OsaurusAI/Qwen3.6-35B-A3B-JANGTQ4",
            scenario: "system prompt plus visible answer",
            verdict: .proven,
            requirements: [
                .visibleOutput,
                .tokensPerSecond,
                .noParserMarkerLeak,
                .multiTurnCoherency,
                .systemPromptInjection,
            ],
            artifactPaths: ["/tmp/osaurus-proof/summary.json"],
            visibleOutput: "Gerald answers with the requested name.",
            tokensPerSecond: 18.4,
            generationTokenCount: 42,
            finishReason: "stop",
            systemPromptEvidence: RuntimeProofSystemPromptEvidence(
                sourceTracePassed: true,
                matchingSectionIds: [PromptSectionID.persona],
                staticPrefixContainsExpectedPrompt: true,
                renderedPromptContainsExpectedPrompt: true
            ),
            systemPromptProbePassed: true,
            multiTurnCoherent: true
        )

        let result = RuntimeProofValidator.validate(row)

        #expect(result.isAcceptableForProvenClaim)
        #expect(result.blockers.isEmpty)
    }

    @Test("proven generation row without token/s is blocked")
    func missingTokenRateBlocksProvenRow() {
        let row = RuntimeProofRow(
            modelId: "local-model",
            scenario: "visible output without stats",
            verdict: .proven,
            requirements: [.visibleOutput, .tokensPerSecond],
            artifactPaths: ["/tmp/osaurus-proof/summary.json"],
            visibleOutput: "hello",
            generationTokenCount: 5
        )

        let result = RuntimeProofValidator.validate(row)

        #expect(!result.isAcceptableForProvenClaim)
        #expect(result.blockers.map(\.requirement).contains(.tokensPerSecond))
    }

    @Test("parser markers in visible output block proof")
    func parserLeakBlocksProof() {
        let row = RuntimeProofRow(
            modelId: "Gemma4",
            scenario: "tool marker leakage",
            verdict: .proven,
            requirements: [.visibleOutput, .tokensPerSecond, .noParserMarkerLeak],
            artifactPaths: ["/tmp/osaurus-proof/summary.json"],
            visibleOutput: "Here is the answer <tool_call>{}</tool_call>",
            tokensPerSecond: 9.1,
            generationTokenCount: 12
        )

        let result = RuntimeProofValidator.validate(row)

        #expect(!result.isAcceptableForProvenClaim)
        #expect(result.blockers.map(\.requirement).contains(.noParserMarkerLeak))
    }

    @Test("hybrid SSM cache proof requires companion hits")
    func hybridCacheRequiresCompanionHit() {
        let row = RuntimeProofRow(
            modelId: "Ling-2.6-flash-JANGTQ2",
            scenario: "warm cache row",
            verdict: .proven,
            requirements: [.tokensPerSecond, .cacheHit],
            artifactPaths: ["/tmp/osaurus-proof/cache.json"],
            tokensPerSecond: 12.7,
            generationTokenCount: 15,
            cacheEvidence: RuntimeProofCacheEvidence(
                topology: .hybridSSM,
                kvLayerCount: 4,
                diskL2Hits: 2,
                ssmCompanionHits: 0
            )
        )

        let result = RuntimeProofValidator.validate(row)

        #expect(!result.isAcceptableForProvenClaim)
        #expect(result.blockers.map(\.requirement).contains(.cacheHit))
    }

    @Test("media rows require real media path evidence")
    func mediaRowsRequireMediaProof() {
        let row = RuntimeProofRow(
            modelId: "Gemma4-audio",
            scenario: "audio attachment",
            verdict: .proven,
            requirements: [.tokensPerSecond, .visibleOutput, .mediaPayload],
            artifactPaths: ["/tmp/osaurus-proof/audio.json"],
            visibleOutput: "The clip contains spoken words.",
            tokensPerSecond: 5.2,
            generationTokenCount: 17,
            mediaEvidence: RuntimeProofMediaEvidence(
                payloadKind: "audio/wav",
                payloadBytes: 48_000,
                cacheSaltRecorded: true,
                mediaCacheHitValidated: false,
                routedThroughMediaPath: true
            )
        )

        let result = RuntimeProofValidator.validate(row)

        #expect(!result.isAcceptableForProvenClaim)
        #expect(result.blockers.map(\.requirement).contains(.mediaPayload))
    }

    @Test("system prompt proof requires source trace evidence")
    func systemPromptProofRequiresSourceTrace() {
        let row = RuntimeProofRow(
            modelId: "local-model",
            scenario: "configured persona probe",
            verdict: .proven,
            requirements: [.systemPromptInjection],
            artifactPaths: ["/tmp/osaurus-proof/system-prompt.json"],
            systemPromptProbePassed: true
        )

        let result = RuntimeProofValidator.validate(row)

        #expect(!result.isAcceptableForProvenClaim)
        #expect(result.blockers.map(\.requirement).contains(.systemPromptInjection))
    }

    @Test("system prompt source trace alone does not prove live injection")
    func systemPromptSourceTraceAloneDoesNotPass() {
        let row = RuntimeProofRow(
            modelId: "local-model",
            scenario: "configured persona source trace only",
            verdict: .proven,
            requirements: [.systemPromptInjection],
            artifactPaths: ["/tmp/osaurus-proof/system-prompt.json"],
            systemPromptEvidence: RuntimeProofSystemPromptEvidence(
                sourceTracePassed: true,
                matchingSectionIds: [PromptSectionID.persona],
                staticPrefixContainsExpectedPrompt: true,
                renderedPromptContainsExpectedPrompt: true
            ),
            systemPromptProbePassed: false
        )

        let result = RuntimeProofValidator.validate(row)

        #expect(!result.isAcceptableForProvenClaim)
        #expect(result.blockers.map(\.requirement).contains(.systemPromptInjection))
    }

    @Test("failed rows may be preserved with warnings instead of blockers")
    func failedRowsKeepEvidenceWithoutBlockingClassification() {
        let row = RuntimeProofRow(
            modelId: "Qwen",
            scenario: "crash repro",
            verdict: .failed,
            requirements: [.tokensPerSecond, .visibleOutput],
            artifactPaths: []
        )

        let result = RuntimeProofValidator.validate(row)

        #expect(result.blockers.isEmpty)
        #expect(result.issues.contains { $0.severity == .warning })
    }
}
