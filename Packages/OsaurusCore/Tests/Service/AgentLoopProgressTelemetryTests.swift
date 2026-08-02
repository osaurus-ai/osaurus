import Foundation
import Testing

@testable import OsaurusCore

@Suite("Agent-loop progress and throughput attribution")
struct AgentLoopProgressTelemetryTests {

    @Test("reasoning deltas emit first and periodic count-only progress")
    func periodicReasoningProgress() {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        var tracker = AgentLoopStepProgressTracker(
            step: 3,
            startedAt: startedAt,
            reportInterval: 30
        )

        #expect(
            AgentLoopStepProgressTracker.startMessage(step: 3)
                == "[evals][agent-loop] step=3 phase=model_start"
        )
        #expect(
            tracker.observe(
                channel: .reasoning,
                characterCount: 12,
                at: startedAt.addingTimeInterval(1)
            )
                == "[evals][agent-loop] step=3 phase=decode elapsed=1.0s "
                    + "channel=reasoning deltas=1 contentChars=0 reasoningChars=12 toolChars=0"
        )
        #expect(
            tracker.observe(
                channel: .content,
                characterCount: 4,
                at: startedAt.addingTimeInterval(10)
            ) == nil
        )
        #expect(
            tracker.observe(
                channel: .toolEnvelope,
                characterCount: 9,
                at: startedAt.addingTimeInterval(31)
            )
                == "[evals][agent-loop] step=3 phase=decode elapsed=31.0s "
                    + "channel=tool_envelope deltas=3 contentChars=4 reasoningChars=12 toolChars=9"
        )
    }

    @Test("terminal line distinguishes measured throughput from unavailable")
    func terminalThroughputAttribution() {
        let unavailable = AgentLoopStepProgressTracker.terminalMessage(
            step: 1,
            stopReason: "tool_calls",
            contentCharacters: 0,
            reasoningCharacters: 84,
            toolEnvelopeCharacters: 120,
            decodeTokensPerSecond: nil,
            throughputAttribution: "unavailable_tool_call_before_vmlx_info"
        )
        #expect(
            unavailable.contains(
                "decodeThroughput=unavailable(unavailable_tool_call_before_vmlx_info)"
            )
        )

        let measured = AgentLoopStepProgressTracker.terminalMessage(
            step: 2,
            stopReason: "stop",
            contentCharacters: 42,
            reasoningCharacters: 0,
            toolEnvelopeCharacters: 0,
            decodeTokensPerSecond: 19.875,
            throughputAttribution: "measured_vmlx_info"
        )
        #expect(measured.contains("decodeThroughput=19.8750_tok_s(measured_vmlx_info)"))
    }

    @Test("legacy step diagnostics decode with explicit unavailable attribution")
    func legacyStepDiagnosticDecode() throws {
        let legacy = Data(
            #"{"step":1,"stopReason":"tool_calls","contentCharacterCount":0,"reasoningCharacterCount":32,"contentPreview":null,"reasoningPreview":"thinking","sawToolCallProgress":true,"pendingToolName":"file_read","toolArgumentCharacters":48,"completionTokens":null,"requestedEnableThinking":true,"thinkingState":"explicitEnabled"}"#.utf8
        )

        let decoded = try JSONDecoder().decode(
            AgentLoopTranscript.StepDiagnostic.self,
            from: legacy
        )
        #expect(decoded.decodeTokensPerSecond == nil)
        #expect(decoded.decodeThroughputAttribution == "unavailable_legacy_transcript")
    }

    @Test("measured step diagnostic preserves runtime throughput provenance")
    func measuredStepDiagnosticRoundTrip() throws {
        let source = AgentLoopTranscript.StepDiagnostic(
            step: 4,
            stopReason: "stop",
            contentCharacterCount: 18,
            reasoningCharacterCount: 0,
            contentPreview: "done",
            reasoningPreview: nil,
            sawToolCallProgress: false,
            pendingToolName: nil,
            toolArgumentCharacters: 0,
            completionTokens: 9,
            decodeTokensPerSecond: 20.25,
            decodeThroughputAttribution: "measured_vmlx_info",
            requestedEnableThinking: false
        )
        let decoded = try JSONDecoder().decode(
            AgentLoopTranscript.StepDiagnostic.self,
            from: JSONEncoder().encode(source)
        )
        #expect(decoded.decodeTokensPerSecond == 20.25)
        #expect(decoded.decodeThroughputAttribution == "measured_vmlx_info")
    }
}
