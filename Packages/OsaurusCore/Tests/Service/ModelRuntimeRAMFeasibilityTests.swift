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

        let atLimit = assess(footprint: softLimit, physical: physical, available: physical)
        #expect(atLimit.verdict == .ok)
        #expect(atLimit.loadPressureSeverity == .none)

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

    @Test("Low free pages alone warns but never blocks")
    func lowAvailableWarnsWithoutBlocking() {
        let physical = 100 * gb
        let thresholds = ServerRuntimeSettingsStore.modelLoadRAMThresholds()
        let softLimit = Int64(Double(physical) * thresholds.soft)

        // Projection is comfortably inside the soft limit, but immediately
        // free pages are short — advisory tight, send still allowed (unified
        // memory can compress/purge to make room).
        let f = assess(
            footprint: softLimit / 2,
            physical: physical,
            available: softLimit / 4
        )

        #expect(f.verdict == .tight)
        #expect(f.loadPressureSeverity == .warn)
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
            timestamp: Date()
        )
        #expect(f.loadPressureSeverity == .block)

        // And a .tight verdict with bytes inside the soft limit still warns
        // (low-available advisory case).
        let warnOnly = ModelRuntime.RAMFeasibility(
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
            timestamp: Date()
        )
        #expect(warnOnly.loadPressureSeverity == .warn)
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
}
