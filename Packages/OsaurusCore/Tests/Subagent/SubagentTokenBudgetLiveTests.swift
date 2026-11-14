import Foundation
import Testing

@testable import OsaurusCore

/// Run alone with the matching metallib, an isolated OSAURUS_TEST_ROOT,
/// OSU_MODELS_DIR and OSAURUS_RAM_CONTRACT_MODEL. Native bundle samplers only.
@Suite("Live delegated token contract", .serialized, .enabled(if:
    ProcessInfo.processInfo.environment["OSAURUS_RAM_CONTRACT_LIVE"] == "1"
))
struct SubagentTokenBudgetLiveTests {
    @Test("real tokenizer refusal leaves the model usable for sequential follow-up turns")
    func exactTokenizerRefusalAndFollowup() async throws {
        let model = try #require(ProcessInfo.processInfo.environment["OSAURUS_RAM_CONTRACT_MODEL"])
        let input = String(repeating: "1 2 3 4 5 6 7 8 9 0 ", count: 1_000)
        let contract = try #require(DelegatedRunContract.derive(
            seedCharacters: input.count, systemPromptCharacters: 0, toolSchemaTokens: 0,
            budgets: SubagentBudgets(), toolEnabled: false, resolvedContextWindow: 65_536
        ))
        let peak = LiveContractFootprint()
        let sampler = Task {
            while !Task.isCancelled {
                await peak.sample()
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
        }
        do {
            for run in 0..<2 {
                do {
                    _ = try await MLXService.shared.generateOneShot(
                        messages: [ChatMessage(role: "user", content: input)],
                        parameters: GenerationParameters(
                            temperature: nil, maxTokens: contract.responseTokens,
                            admissionPositionLimit: contract.contextPositions
                        ),
                        requestedModel: model
                    )
                    Issue.record("oversized tokenized request reached generation")
                } catch let error as AdmissionPositionLimit {
                    #expect(error.promptTokens >= 20_000)
                    #expect(error.limit == contract.contextPositions)
                    print("TOKEN_CONTRACT_REFUSAL run=\(run) prompt=\(error.promptTokens) output=\(error.outputTokens) limit=\(error.limit)")
                }
                let marker = "RAM_LIVE_\(run)_OK"
                let stream = try await MLXService.shared.streamDeltas(
                    messages: [ChatMessage(role: "user", content: "Return exactly \(marker).")],
                    parameters: GenerationParameters(
                        temperature: nil, maxTokens: 2048,
                        sessionId: "ram-live-contract-\(run)", admissionPositionLimit: 4096
                    ),
                    requestedModel: model, stopSequences: []
                )
                var text = ""
                var sawStats = false
                for try await delta in stream {
                    if let stats = StreamingStatsHint.decode(delta) {
                        sawStats = true
                        #expect(stats.tokensPerSecond > 0)
                        #expect(!stats.unclosedReasoning)
                        #expect(stats.stopReason != "length")
                        print("TOKEN_CONTRACT_GENERATION run=\(run) tokens=\(stats.tokenCount) tps=\(stats.tokensPerSecond) stop=\(stats.stopReason ?? "unknown")")
                    } else if !delta.hasPrefix("\u{FFFE}") {
                        text += delta
                    }
                }
                #expect(sawStats)
                #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == marker)
                let footprint = try #require(ProcessMemoryProbe.currentPhysFootprintMB())
                let occupancy = await ModelRuntime.shared.batchEngineCapacitySnapshot(for: model)
                print("TOKEN_CONTRACT_RESULT run=\(run) text=\(text.debugDescription) footprint_mib=\(footprint) active=\(occupancy?.activeCount ?? -1) pending=\(occupancy?.pendingCount ?? -1)")
            }
        } catch {
            sampler.cancel()
            await sampler.value
            print("TOKEN_CONTRACT_PEAK footprint_mib=\(await peak.maximum)")
            await ModelRuntime.shared.clearAll()
            throw error
        }
        sampler.cancel()
        await sampler.value
        print("TOKEN_CONTRACT_PEAK footprint_mib=\(await peak.maximum)")
        await ModelRuntime.shared.clearAll()
    }
}

private actor LiveContractFootprint {
    var maximum: Double = 0
    func sample() {
        if let measured = ProcessMemoryProbe.currentPhysFootprintMB() {
            maximum = max(maximum, measured)
        }
    }
}
