import Foundation
import Testing

@testable import OsaurusCore

@Suite("Memory warning lifecycle — no model allocation")
struct MemoryWarningStateTests {
    private func swap(
        _ severity: SwapPressureMonitor.Severity = .elevated,
        model: String = "gemma",
        emulated: Bool = false,
        phase: SwapPressureMonitor.Phase = .resident
    ) -> SwapPressureMonitor.State {
        .init(
            severity: severity,
            phase: phase,
            modelName: model,
            baselineUsedBytes: 1 << 30,
            swapUsedBytes: 3 << 30,
            swapTotalBytes: 8 << 30,
            growthSinceBaselineBytes: 2 << 30,
            peakGrowthBytes: 2 << 30,
            episodeElapsedSeconds: 3,
            processFootprintBytes: 1 << 30,
            swapinsPerSecond: 0,
            decompressionsPerSecond: 0,
            emulated: emulated
        )
    }

    private func prediction(
        model: String = "gemma",
        available: Int64 = 8 << 30,
        required: Int64 = 12 << 30,
        limit: Int64 = 14 << 30,
        severity: ModelRuntime.RAMFeasibility.LoadPressureSeverity = .warn,
        simulated: Bool = false
    ) -> MemoryWarningState.Prediction {
        .init(
            model: model,
            severity: severity,
            requiredBytes: required,
            availableBytes: available,
            hardLimitBytes: limit,
            simulated: simulated
        )
    }

    private func resolve(
        _ phase: MemoryWarningState.Phase,
        swap: SwapPressureMonitor.State? = nil,
        dismissed: SwapPressureMonitor.Severity? = nil
    ) -> MemoryWarningState {
        MemoryWarningState.resolve(
            canonicalModel: "gemma",
            phase: phase,
            assessment: nil,
            swap: swap,
            acknowledged: nil,
            dismissedSwapSeverity: dismissed
        )
    }

    @Test func unloadedNeverClaimsMeasuredSwap() {
        #expect(resolve(.unloaded, swap: swap()) == .none)
        #expect(resolve(.unloaded, swap: swap(.critical, model: "other")) == .none)
    }

    @Test func simulationUsesActualRuntimePhase() {
        let s = swap(model: "Simulated Model", emulated: true)
        guard case .predicted(let p) = resolve(.unloaded, swap: s) else {
            Issue.record("Unloaded simulation must predict, not offer Unload")
            return
        }
        #expect(p.simulated)
        #expect(p.model == "gemma")
        #expect(resolve(.loading, swap: s) == .loading(s))
        #expect(resolve(.resident, swap: s) == .loaded(s))
        #expect(resolve(.unloaded, swap: swap(.none, emulated: true)) == .none)
    }

    @Test func anotherModelsEpisodeCannotDriveActions() {
        #expect(resolve(.loading, swap: swap(model: "other")) == .none)
        #expect(resolve(.resident, swap: swap(model: "other")) == .none)
        let s = swap(model: "GEMMA", phase: .loading)
        // Another model may be loading while this selected one is resident.
        #expect(resolve(.resident, swap: s) == .loaded(s))
        #expect(resolve(.loading, swap: s) == .loading(s))
    }

    @Test func dismissMeasuredSeverityOnlyUntilEscalation() {
        #expect(resolve(.loading, swap: swap(), dismissed: .elevated) == .none)
        let critical = swap(.critical)
        #expect(resolve(.loading, swap: critical, dismissed: .elevated) == .loading(critical))
    }

    @Test func acknowledgementExpiresForWorseRiskAndDifferentIdentity() {
        let old = prediction()
        #expect(old.isCovered(by: old))
        #expect(prediction(available: 9 << 30).isCovered(by: old))
        #expect(!prediction(available: 7 << 30).isCovered(by: old))
        #expect(!prediction(model: "ornith").isCovered(by: old))
        #expect(!prediction(required: 13 << 30).isCovered(by: old))
        #expect(!prediction(limit: 13 << 30).isCovered(by: old))
        #expect(!prediction(severity: .block).isCovered(by: old))
        #expect(!prediction(simulated: true).isCovered(by: old))
        #expect(!old.isCovered(by: nil))
        #expect(old.isCovered(by: prediction(severity: .block)))
    }

    @Test func realPredictionUsesExistingProjectionWithoutChangingAdmission() {
        let assessment = ModelRuntime.RAMFeasibility(
            modelName: "catalog/Gemma",
            verdict: .tight,
            incomingWeightsBytes: 17 << 30,
            incomingLoadFootprintBytes: 17 << 30,
            residentWeightsBytes: 0,
            kvHeadroomBytes: 1 << 30,
            projectedBytes: 18 << 30,
            physicalMemoryBytes: 16 << 30,
            availableMemoryBytes: 10 << 30,
            requiredAvailableBytes: 18 << 30,
            softLimitBytes: 12 << 30,
            hardLimitBytes: 14 << 30,
            automaticMemoryLimitsDisabled: false,
            gpuBudgetBytes: 12 << 30,
            timestamp: Date()
        )
        let result = MemoryWarningState.resolve(
            canonicalModel: "gemma",
            phase: .unloaded,
            assessment: assessment,
            swap: nil,
            acknowledged: nil,
            dismissedSwapSeverity: nil
        )
        guard case .predicted(let p) = result else { Issue.record("Missing prediction"); return }
        #expect(p.severity == .block)
        #expect(p.requiredBytes == 18 << 30)
        #expect(
            MemoryWarningState.resolve(
                canonicalModel: "gemma",
                phase: .unloaded,
                assessment: assessment,
                swap: nil,
                acknowledged: p,
                dismissedSwapSeverity: nil
            ) == .none
        )
        #expect(assessment.verdict == .tight)
        #expect(!assessment.automaticMemoryLimitsDisabled)
    }

    @Test func sendAndVoiceRetainDraftThroughReadOnlyRecheck() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Views/Chat/FloatingInputCard.swift"),
            encoding: .utf8
        )
        let start = try #require(source.range(of: "private func syncAndSend()"))
        let end = try #require(source.range(of: "private func commitSend("))
        let check = String(source[start.lowerBound ..< end.lowerBound])
        #expect(check.contains("projectedLoadFeasibility(for: model)"))
        #expect(check.contains("memoryWarningPhase(forCanonicalName: canonical)"))
        #expect(check.contains("inputHistoryKey == session"))
        #expect(check.contains("memoryContextGeneration == contextGeneration"))
        #expect(check.contains("localText == message"))
        #expect(!check.contains("localText = \"\""))
        #expect(!source.contains("guard !ramBlocked"))
        #expect(source.components(separatedBy: "onSend(message)").count == 2)
        #expect(!source.contains("onSend(fullMessage)"))
        // MLXModel.name is human-readable; the tuple-returning helper is the
        // runtime's canonical name. A display-name lookup left the live
        // warning predicted while /health already reported a resident model.
        #expect(check.contains("findInstalledModelFromCache(named: model)?.name"))
        #expect(!source.contains("findInstalledMLXModelFromCache(named: model)?.name"))
        #expect(!source.contains("findInstalledMLXModelFromCache(named: selectedModel ?? \"\")?.name"))
        #expect(source.contains("resolvedMemoryWarning == .none"))
        #expect(!source.contains("(pendingLoadFeasibility?.loadPressureSeverity ?? .none) == .none"))
        let queuedStart = try #require(source.range(of: "private func checkMemoryAndSendQueuedNow()"))
        let queuedEnd = try #require(source.range(of: "private func dispatchQueuedNow()"))
        let queuedCheck = String(source[queuedStart.lowerBound ..< queuedEnd.lowerBound])
        #expect(queuedCheck.contains("projectedLoadFeasibility(for: model)"))
        #expect(queuedCheck.contains("queuedSend == pending"))
        #expect(queuedCheck.contains("if case .predicted = resolvedMemoryWarning { return }"))
        #expect(!queuedCheck.contains("queuedSend = nil"))
    }

    @Test func lowAvailableMemoryIsAdvisoryEvenForASmallModel() {
        let assessment = ModelRuntime.RAMFeasibility(
            modelName: "small",
            verdict: .tight,
            incomingWeightsBytes: 4 << 30,
            incomingLoadFootprintBytes: 4 << 30,
            residentWeightsBytes: 0,
            kvHeadroomBytes: 1 << 30,
            projectedBytes: 5 << 30,
            physicalMemoryBytes: 16 << 30,
            availableMemoryBytes: 1 << 30,
            requiredAvailableBytes: 5 << 30,
            softLimitBytes: 12 << 30,
            hardLimitBytes: 14 << 30,
            automaticMemoryLimitsDisabled: false,
            gpuBudgetBytes: 12 << 30,
            timestamp: Date()
        )
        #expect(assessment.loadPressureSeverity == .none)
        #expect(MemoryWarningState.predictionSeverity(assessment) == .warn)
        #expect(MemoryWarningState.predictionSeverity(nil) == .none)
    }
}
