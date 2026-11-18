import Foundation
import MLXLMCommon
import Testing

@testable import OsaurusCore

/// Speculative Decoding Off (AR) <-> On (Adaptive), and the untouched default -> an explicit On, must not reload a
/// resident model whose loaded graph already serves the new selection. Measured before (m5 GUI runs, 2026-10-29):
/// every switch of the row unloaded MiniMax-M3.1-Flash-JANGHT1.9 (95 GB) and the next send reloaded it, 13.6-14.4 s.
@Suite("Speculative toggle keeps resident weights", .serialized)
struct SpeculativeToggleResidencyTests {
    private static let segments: [String?] = [nil, "off", "auto"]

    private func facts(_ plan: M31LoadPlan) -> SpeculativeLoadFacts {
        SpeculativeLoadFacts(loadConfiguration: plan.loadConfiguration, draftStrategy: plan.loaded)
    }

    private func resident(_ plan: M31LoadPlan) -> SpeculativeLoadFacts.Resident {
        .init(strategy: plan.loaded, admission: plan.admission, facts: facts(plan))
    }

    @Test("MiniMax-M3.1 (bundled DSpark): every switch of the row keeps the model; requests follow the new setting")
    func m31EverySwitchKeepsTheModel() throws {
        let bundle = try MiniMaxM31Bundle.materialize()
        defer { MiniMaxM31Bundle.remove(bundle) }
        for previous in Self.segments {
            for next in Self.segments where next != previous {
                let label = "\(previous ?? "default") -> \(next ?? "default")"
                let loadedPlan = try M31LoadPlan(bundle: bundle, mtp: try m31SavedMTP(segment: previous))
                let nextMTP = try m31SavedMTP(segment: next)
                let nextPlan = try M31LoadPlan(bundle: bundle, mtp: nextMTP)
                // The settings-level predicate still flags the row as a possible load input (any bundle) ...
                var before = VMLXServerRuntimeSettings()
                before.mtp = try m31SavedMTP(segment: previous)
                var after = VMLXServerRuntimeSettings()
                after.mtp = nextMTP
                #expect(ServerController.onlySpeculativeLoadInputsChanged(previous: before, next: after)
                    == ServerController.loadedModelRuntimeInputsRequireRefresh(previous: before, next: after), "\(label)")
                // ... but for THIS bundle the load does not change: keep the 95 GB model.
                #expect(
                    SpeculativeLoadFacts.keepsResidentWeights(loaded: facts(loadedPlan), next: facts(nextPlan)),
                    "\(label): \(ModelRuntime.describeSpeculativeLoadFacts(facts(loadedPlan))) vs \(ModelRuntime.describeSpeculativeLoadFacts(facts(nextPlan)))")
                // The kept holder serves the next setting's requests exactly: Off -> no strategy (vmlx neither
                // drafts nor verifies with an attached drafter), On / default -> the bundled drafter.
                let kept = SpeculativeLoadFacts.residentAfterKeptChange(
                    resident: resident(loadedPlan), next: resident(nextPlan))
                let request = try kept.admission.requestStrategy(loaded: kept.strategy, mtp: nextMTP)
                let resolved = ModelRuntime.requestDraftStrategy(kept.strategy, mtp: nextMTP)
                if next == "off" {
                    #expect(request == nil, "\(label)")
                    #expect(resolved == nil, "\(label)")
                } else {
                    #expect(request.m31DSparkPath == loadedPlan.drafterDirectory.standardizedFileURL.path, "\(label)")
                    #expect(resolved.m31DSparkPath == loadedPlan.drafterDirectory.standardizedFileURL.path, "\(label)")
                }
            }
        }
    }

    @Test("A chain Off -> On -> Off -> On on one resident model stays correct at every step")
    func m31ChainOfSwitches() throws {
        let bundle = try MiniMaxM31Bundle.materialize()
        defer { MiniMaxM31Bundle.remove(bundle) }
        // Loaded under Off (no drafter named yet), then the row is switched four times without a reload.
        var state = resident(try M31LoadPlan(bundle: bundle, mtp: try m31SavedMTP(segment: "off")))
        for segment in ["auto", "off", nil, "off", "auto"] as [String?] {
            let mtp = try m31SavedMTP(segment: segment)
            let next = resident(try M31LoadPlan(bundle: bundle, mtp: mtp))
            #expect(SpeculativeLoadFacts.keepsResidentWeights(loaded: state.facts, next: next.facts))
            state = SpeculativeLoadFacts.residentAfterKeptChange(resident: state, next: next)
            let request = try state.admission.requestStrategy(loaded: state.strategy, mtp: mtp)
            #expect((request?.kindName ?? "none") == (segment == "off" ? "none" : "dspark"), "\(segment ?? "default")")
        }
    }

    @Test("A kept switch is not undone by the per-request preparation check (requiresPreparation)")
    func m31KeptSwitchNeedsNoRequestPreparation() throws {
        let bundle = try MiniMaxM31Bundle.materialize()
        defer { MiniMaxM31Bundle.remove(bundle) }
        let chain: [String?] = ["auto", "off", nil, "off", "auto", nil, "auto"]
        for start in Self.segments {
            let startMTP = try m31SavedMTP(segment: start)
            var state = resident(try M31LoadPlan(bundle: bundle, mtp: startMTP))
            var prepared = startMTP
            for segment in chain where segment != start {
                let mtp = try m31SavedMTP(segment: segment)
                let next = resident(try M31LoadPlan(bundle: bundle, mtp: mtp))
                let label = "\(start ?? "default") ... -> \(segment ?? "default")"
                #expect(SpeculativeLoadFacts.keepsResidentWeights(loaded: state.facts, next: next.facts), "\(label)")
                state = SpeculativeLoadFacts.residentAfterKeptChange(resident: state, next: next)
                prepared = AgentSpeculationPolicy.preparedAfterKeptChange(previous: prepared, next: mtp)
                #expect(
                    !AgentSpeculationPolicy.requiresPreparation(
                        previous: prepared, next: mtp, hasLoadedStrategy: state.strategy != nil), "\(label)")
            }
        }
        // Control: had the holder kept the Off it was loaded with, the next On request would evict and reload the
        // graph it was just kept with.
        let off = try m31SavedMTP(segment: "off")
        let on = try m31SavedMTP(segment: "auto")
        #expect(AgentSpeculationPolicy.requiresPreparation(previous: off, next: on, hasLoadedStrategy: true))
        #expect(AgentSpeculationPolicy.preparedAfterKeptChange(previous: off, next: on) == on)
        #expect(AgentSpeculationPolicy.preparedAfterKeptChange(previous: on, next: off) == on)
    }

    @Test("Controls: a change of the loaded graph or of the drafter still reloads")
    func realLoadChangesStillReload() {
        let dspark = SpeculativeLoadFacts.identity(.dspark(drafterPath: URL(fileURLWithPath: "/b/dspark")))
        let otherDSpark = SpeculativeLoadFacts.identity(.dspark(drafterPath: URL(fileURLWithPath: "/c/dspark")))
        let dflash2 = SpeculativeLoadFacts.identity(.dflash2(drafterPath: URL(fileURLWithPath: "/b/dflash2")))
        let dflash2Pinned = SpeculativeLoadFacts.identity(
            .dflash2(drafterPath: URL(fileURLWithPath: "/b/dflash2"), blockSize: 8))
        let uno = SpeculativeLoadFacts.identity(.uno(adapterPath: URL(fileURLWithPath: "/b/uno")))
        let mtp3 = SpeculativeLoadFacts.identity(.nativeMTP(depth: 3))
        let mtp1 = SpeculativeLoadFacts.identity(.nativeMTP(depth: 1))
        func f(_ graph: Bool, _ s: SpeculativeLoadFacts.Strategy?, manual: Int? = nil) -> SpeculativeLoadFacts {
            SpeculativeLoadFacts(nativeMTPInGraph: graph, nativeMTPManualDepth: manual, strategy: s)
        }
        let keep = SpeculativeLoadFacts.keepsResidentWeights
        // Kept: lazily attached DSpark, unchanged strategies, native MTP depth (per request).
        #expect(keep(f(false, nil), f(false, dspark)))
        #expect(keep(f(false, dspark), f(false, nil)))
        #expect(keep(f(false, dspark), f(false, dspark)))
        #expect(keep(f(true, mtp3), f(true, mtp1)))
        #expect(keep(f(false, nil), f(false, nil)))
        // Reloaded: the native head enters / leaves the graph (Flash-Next Off <-> On), a manual depth scope,
        // another DSpark drafter, DFlash 2 / Uno appearing or changing width, an opaque draft model.
        #expect(!keep(f(false, nil), f(true, mtp3)))
        #expect(!keep(f(true, mtp3), f(false, nil)))
        #expect(!keep(f(true, mtp3), f(true, mtp3, manual: 2)))
        #expect(!keep(f(false, dspark), f(false, otherDSpark)))
        #expect(!keep(f(false, nil), f(false, dflash2)))
        #expect(!keep(f(false, dflash2), f(false, nil)))
        #expect(!keep(f(false, dflash2), f(false, dflash2Pinned)))
        #expect(!keep(f(false, nil), f(false, uno)))
        #expect(!keep(f(false, dspark), f(false, dflash2)))
        let opaque = SpeculativeLoadFacts.Strategy(kind: "autoregressive", opaque: true)
        #expect(!keep(f(false, opaque), f(false, opaque)))
    }

    @Test("Any other load input still clears every resident model")
    func otherLoadInputsStillClear() {
        var previous = VMLXServerRuntimeSettings()
        previous.mtp = .init(mode: .auto)
        var next = previous
        next.mtp = .init(mode: .off)
        #expect(ServerController.onlySpeculativeLoadInputsChanged(previous: previous, next: next))
        next.multimodal.enableVideo.toggle()
        #expect(!ServerController.onlySpeculativeLoadInputsChanged(previous: previous, next: next))
        #expect(ServerController.loadedModelRuntimeInputsRequireRefresh(previous: previous, next: next))
        // No load input changed at all: nothing to judge.
        #expect(!ServerController.onlySpeculativeLoadInputsChanged(previous: previous, next: previous))
    }
}
