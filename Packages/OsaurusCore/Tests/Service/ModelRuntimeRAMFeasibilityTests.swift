//
//  ModelRuntimeRAMFeasibilityTests.swift
//  Tests for the candidate-load RAM projection backing the chat input's
//  tight-fit disclaimer and send gate.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ModelRuntime RAM feasibility — projection + severity mapping")
struct ModelRuntimeRAMFeasibilityTests {

    private let gb: Int64 = 1024 * 1024 * 1024

    @Test("Resolved allocator cap cannot be overwritten by weight-scaled cache limit")
    func resolvedAllocatorCapWins() {
        let mib = 1024 * 1024
        #expect(
            ModelRuntime.effectiveMLXCacheLimit(
                dynamicLimit: 1024 * mib,
                configuredLimits: [128 * mib]
            ) == 128 * mib
        )
        #expect(
            ModelRuntime.effectiveMLXCacheLimit(
                dynamicLimit: 1024 * mib,
                configuredLimits: [nil]
            ) == 1024 * mib
        )
        #expect(
            ModelRuntime.effectiveMLXCacheLimit(
                dynamicLimit: 1024 * mib,
                configuredLimits: [1024 * mib, 128 * mib, nil]
            ) == 128 * mib
        )
        #expect(
            ModelRuntime.effectiveMLXCacheLimit(
                dynamicLimit: 0,
                configuredLimits: [128 * mib]
            ) == 0
        )
    }

    @Test("Memory safety bounds live hybrid companion snapshots")
    func memorySafetyBoundsSSMCompanionSnapshots() {
        #expect(ModelRuntime.ssmCompanionEntryLimit(for: .performance) == 50)
        #expect(ModelRuntime.ssmCompanionEntryLimit(for: .balanced) == 8)
        #expect(ModelRuntime.ssmCompanionEntryLimit(for: .safeAuto) == 2)
        #expect(ModelRuntime.ssmCompanionEntryLimit(for: .strict) == 1)
        #expect(ModelRuntime.ssmCompanionEntryLimit(for: .diagnosticDangerous) == 50)
    }

    /// Builds an assessment through the shared verdict math with synthetic
    /// byte counts. Thresholds come from the same store production uses, so
    /// expectations are computed from the resolved values rather than
    /// hardcoded 0.70/0.90.
    private func assess(
        footprint: Int64,
        kvHeadroom: Int64 = 0,
        resident: Int64 = 0,
        inflightOther: Int64 = 0,
        physical: Int64,
        available: Int64
    ) -> ModelRuntime.RAMFeasibility {
        ModelRuntime.buildRAMFeasibility(
            modelName: "test-model",
            incomingWeightsBytes: footprint,
            incomingLoadFootprintBytes: footprint,
            resident: resident,
            inflightOther: inflightOther,
            kvHeadroom: kvHeadroom,
            physical: physical,
            available: available
        )
    }

    // MARK: - Shared builder: verdict boundaries

    @Test("Comfortable fit is ok with severity none")
    func comfortableFitIsOK() {
        let physical = 100 * gb
        let thresholds = ServerRuntimeSettingsStore.modelLoadRAMThresholds()
        let softLimit = Int64(Double(physical) * thresholds.soft)

        // Half the soft limit projected, plenty of free pages.
        let f = assess(
            footprint: softLimit / 2,
            physical: physical,
            available: physical
        )

        #expect(f.verdict == .ok)
        #expect(f.loadPressureSeverity == .none)
        #expect(f.softLimitBytes == softLimit)
        #expect(f.hardLimitBytes == Int64(Double(physical) * thresholds.hard))
        #expect(f.projectedBytes == softLimit / 2)
        #expect(f.requiredAvailableBytes == softLimit / 2)
    }

    @Test("Crossing the soft threshold is tight / warn")
    func softThresholdCrossingWarns() {
        let physical = 100 * gb
        let thresholds = ServerRuntimeSettingsStore.modelLoadRAMThresholds()
        let softLimit = Int64(Double(physical) * thresholds.soft)
        let hardLimit = Int64(Double(physical) * thresholds.hard)

        // The soft threshold (0.80 of RAM) sits *above* the GPU working-set
        // budget (0.75 of RAM on machines over 36 GB), so a single model sized
        // at the soft limit is already past what Metal will keep resident.
        // `verdict` keys off physical memory and stays `.ok`; the UI severity
        // keys off the budget and warns.
        let atLimit = assess(footprint: softLimit, physical: physical, available: physical)
        #expect(atLimit.verdict == .ok)
        #expect(atLimit.exceedsGPUBudget)
        #expect(atLimit.loadPressureSeverity == .warn)

        // Well inside the GPU budget: neither signal fires.
        let comfortable = assess(footprint: softLimit / 2, physical: physical, available: physical)
        #expect(comfortable.verdict == .ok)
        #expect(!comfortable.exceedsGPUBudget)
        #expect(comfortable.loadPressureSeverity == .none)

        let justOver = assess(footprint: softLimit + 1, physical: physical, available: physical)
        #expect(justOver.verdict == .tight)
        #expect(justOver.loadPressureSeverity == .warn)
        #expect(justOver.projectedBytes <= hardLimit)
    }

    @Test("Crossing the hard ceiling blocks send")
    func hardCeilingCrossingBlocks() {
        let physical = 100 * gb
        let thresholds = ServerRuntimeSettingsStore.modelLoadRAMThresholds()
        let hardLimit = Int64(Double(physical) * thresholds.hard)

        let atLimit = assess(footprint: hardLimit, physical: physical, available: physical)
        #expect(atLimit.loadPressureSeverity == .warn)

        let justOver = assess(footprint: hardLimit + 1, physical: physical, available: physical)
        #expect(justOver.verdict == .tight)
        #expect(justOver.loadPressureSeverity == .block)
    }

    @Test("Low free pages alone stays advisory and shows no banner")
    func lowAvailableIsAdvisoryOnly() {
        let physical = 100 * gb
        let thresholds = ServerRuntimeSettingsStore.modelLoadRAMThresholds()
        let softLimit = Int64(Double(physical) * thresholds.soft)

        // Projection is comfortably inside both the soft limit and the GPU
        // budget, but immediately free pages are short. `verdict` records the
        // pressure for health/logs and the load is never blocked — but the
        // chat banner must stay silent: on macOS free pages are almost always
        // scarce (the compressor and file cache return memory on demand), and
        // warning here popped a disclaimer on every launch for models that fit
        // with room to spare.
        let f = assess(
            footprint: softLimit / 2,
            physical: physical,
            available: softLimit / 4
        )

        #expect(f.verdict == .tight)
        #expect(!f.exceedsGPUBudget)
        #expect(f.loadPressureSeverity == .none)
    }

    @Test("Shortfall within the on-demand reclaim slack stays ok")
    func shortfallWithinReclaimSlackStaysOK() {
        let physical = 100 * gb

        // Required exceeds the instantaneous free pages, but by less than
        // the 10%-of-physical slack macOS can reclaim on demand — no banner.
        let f = assess(
            footprint: 25 * gb,
            physical: physical,
            available: 20 * gb
        )

        #expect(f.verdict == .ok)
        #expect(f.loadPressureSeverity == .none)
    }

    @Test("Model larger than physical memory blocks regardless of thresholds")
    func modelLargerThanPhysicalBlocks() {
        let physical = 16 * gb
        let f = assess(
            footprint: 32 * gb,
            kvHeadroom: 2 * gb,
            physical: physical,
            available: physical
        )

        #expect(f.requiredAvailableBytes > f.physicalMemoryBytes)
        #expect(f.loadPressureSeverity == .block)
    }

    @Test("Resident and in-flight bytes count toward the projection")
    func residentAndInflightBytesCountTowardProjection() {
        let physical = 100 * gb
        let thresholds = ServerRuntimeSettingsStore.modelLoadRAMThresholds()
        let softLimit = Int64(Double(physical) * thresholds.soft)

        // Footprint alone fits; resident + in-flight pushes past soft.
        let footprint = softLimit / 2
        let f = assess(
            footprint: footprint,
            resident: softLimit / 2,
            inflightOther: 2,
            physical: physical,
            available: physical
        )

        #expect(f.projectedBytes == footprint + softLimit / 2 + 2)
        #expect(f.verdict == .tight)
        #expect(f.loadPressureSeverity == .warn)
    }

    // MARK: - Severity mapping is pure on the snapshot

    @Test("Severity mapping derives from bytes, not the stored verdict")
    func severityMappingUsesBytes() {
        // A snapshot hand-built with verdict .ok but bytes past the hard
        // limit must still block: the UI gate keys off the byte math so a
        // stale/incoherent verdict can't unblock sending.
        let f = ModelRuntime.RAMFeasibility(
            modelName: "m",
            verdict: .ok,
            incomingWeightsBytes: 95 * gb,
            incomingLoadFootprintBytes: 95 * gb,
            residentWeightsBytes: 0,
            kvHeadroomBytes: 0,
            projectedBytes: 95 * gb,
            physicalMemoryBytes: 100 * gb,
            availableMemoryBytes: 100 * gb,
            requiredAvailableBytes: 95 * gb,
            softLimitBytes: 70 * gb,
            hardLimitBytes: 90 * gb,
            // Isolate the byte math: no budget, so `exceedsGPUBudget` is false.
            gpuBudgetBytes: 0,
            timestamp: Date()
        )
        #expect(f.loadPressureSeverity == .block)

        // A `.tight` verdict driven only by scarce free pages must stay quiet.
        // macOS hands memory back from the compressor and file cache on
        // demand, so a small model on a busy Mac is not worth a banner.
        let lowAvailableOnly = ModelRuntime.RAMFeasibility(
            modelName: "m",
            verdict: .tight,
            incomingWeightsBytes: 10 * gb,
            incomingLoadFootprintBytes: 10 * gb,
            residentWeightsBytes: 0,
            kvHeadroomBytes: 0,
            projectedBytes: 10 * gb,
            physicalMemoryBytes: 100 * gb,
            availableMemoryBytes: 1 * gb,
            requiredAvailableBytes: 10 * gb,
            softLimitBytes: 70 * gb,
            hardLimitBytes: 90 * gb,
            gpuBudgetBytes: 75 * gb,
            timestamp: Date()
        )
        #expect(lowAvailableOnly.loadPressureSeverity == .none)
    }

    // MARK: - GPU working-set budget

    /// Reported against 0.21.10: an M1 Max with 64 GB running Qwen3.6-35B-A3B
    /// MXFP4 (~25.8 GB to load) got the RAM popup on every launch. The model
    /// uses barely half the GPU budget and is nowhere near the soft limit —
    /// only `lowAvailable` fired, because macOS keeps free pages scarce by
    /// design. Nothing here should warn.
    @Test("A comfortably-fitting model never warns just because free pages are scarce")
    func comfortableModelOnBusyMacStaysQuiet() {
        let physical = 64 * gb
        let weights = Int64(18.8 * Double(gb))
        let required = Int64(25.8 * Double(gb))
        let f = ModelRuntime.buildRAMFeasibility(
            modelName: "qwen3.6-35b-a3b-mxfp4-mtp",
            incomingWeightsBytes: weights,
            incomingLoadFootprintBytes: weights,
            resident: 0,
            inflightOther: 0,
            kvHeadroom: required - weights,
            physical: physical,
            // 77% "used" — an ordinary idle macOS desktop.
            available: Int64(0.23 * Double(physical))
        )
        #expect(f.requiredAvailableBytes == required)
        #expect(!f.exceedsGPUBudget)
        #expect(f.loadPressureSeverity == .none)
    }

    /// The Reddit report: a 35B MXFP8 bundle (~42.7 GB) on a 48 GB Mac. Free
    /// RAM looks ample and every physical-memory threshold is satisfied, but
    /// the weights don't fit the 36 GB GPU working set, so macOS pages them
    /// and decode collapses to about a character every ten seconds.
    @Test("A working set past the GPU budget warns even with RAM to spare")
    func exceedingGPUBudgetWarnsOnIdleMac() {
        let physical = 48 * gb
        let required = Int64(42.7 * Double(gb))
        let f = ModelRuntime.buildRAMFeasibility(
            modelName: "ornith-1.0-35b-mxfp8",
            incomingWeightsBytes: required,
            incomingLoadFootprintBytes: required,
            resident: 0,
            inflightOther: 0,
            kvHeadroom: 0,
            physical: physical,
            available: physical
        )
        #expect(f.exceedsGPUBudget)
        #expect(f.loadPressureSeverity == .warn)
    }

    /// Hy3-JANG_2K live case: 94.4 GB materialized footprint plus a ~34 GB
    /// worst-case KV headroom on a 128 GB Mac. The pack loads and decodes
    /// normally (phys_footprint ~96 GB, ~10 tok/s), but charging the full KV
    /// allowance against the hard ceiling disabled the send button with
    /// "needs ~128.3 GB". KV grows lazily under its own runtime cap — the
    /// block judgment uses the resident working set, not weights + max-KV.
    @Test("Worst-case KV headroom does not block a pack whose weights fit")
    func kvHeadroomDoesNotBlockFittingWeights() {
        let physical = 128 * gb
        let f = assess(
            footprint: Int64(94.4 * Double(gb)),
            kvHeadroom: 34 * gb,
            physical: physical,
            available: 100 * gb
        )
        #expect(f.loadPressureSeverity != .block)
    }

    @Test("A 48 GB Mac budgets 36 GB to the GPU")
    func gpuBudgetForFortyEightGigMac() {
        #expect(ModelRuntime.gpuBudgetBytes(physicalMemoryBytes: 48 * gb) == 36 * gb)
    }

    // MARK: - projectedLoadFeasibility guards

    @Test("Unknown and empty model names project to nil")
    func unknownModelProjectsToNil() async {
        let missing = await ModelRuntime.shared.projectedLoadFeasibility(
            for: "osaurus-test-nonexistent-\(UUID().uuidString)"
        )
        #expect(missing == nil)

        let empty = await ModelRuntime.shared.projectedLoadFeasibility(for: "   ")
        #expect(empty == nil)
    }

    // MARK: - Projection suppression (resident / in-flight aliasing)

    @Test("Resident model suppresses the projection regardless of casing")
    func residentModelSuppressesProjection() {
        // The runtime caches under the canonical lowercased repo name; the
        // chat picker resolves a full catalog id down to the same canonical
        // form. Both must hit the resident check.
        #expect(
            ModelRuntime.isProjectionSuppressed(
                canonicalName: "qwen3.6-35b-a3b-mxfp4-mtp",
                residentNames: ["qwen3.6-35b-a3b-mxfp4-mtp"],
                inflightNames: []
            )
        )
        // Defensive: a cache key that kept original casing still matches.
        #expect(
            ModelRuntime.isProjectionSuppressed(
                canonicalName: "qwen3.6-35b-a3b-mxfp4-mtp",
                residentNames: ["Qwen3.6-35B-A3B-MXFP4-MTP"],
                inflightNames: []
            )
        )
    }

    @Test("In-flight load of the same model suppresses the projection")
    func inflightLoadSuppressesProjection() {
        #expect(
            ModelRuntime.isProjectionSuppressed(
                canonicalName: "qwen3.6-35b-a3b-mxfp4-mtp",
                residentNames: [],
                inflightNames: ["qwen3.6-35b-a3b-mxfp4-mtp"]
            )
        )
    }

    @Test("Other resident or in-flight models do not suppress the projection")
    func otherModelsDoNotSuppressProjection() {
        #expect(
            !ModelRuntime.isProjectionSuppressed(
                canonicalName: "qwen3.6-35b-a3b-mxfp4-mtp",
                residentNames: ["gemma-4-12b-qat"],
                inflightNames: ["llama-4-8b-4bit"]
            )
        )
        #expect(
            !ModelRuntime.isProjectionSuppressed(
                canonicalName: "qwen3.6-35b-a3b-mxfp4-mtp",
                residentNames: [],
                inflightNames: []
            )
        )
    }
}
