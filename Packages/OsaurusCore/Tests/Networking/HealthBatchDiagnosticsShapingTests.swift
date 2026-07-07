//
//  HealthBatchDiagnosticsShapingTests.swift
//  OsaurusCoreTests
//
//  Unit coverage for the pure helpers behind the /health
//  `batch_diagnostics` block: JSON shaping (nil snapshot, empty vs
//  populated native-MTP depth summary) and the deadline race that keeps
//  /health responsive when the diagnostics fetch is wedged behind a hung
//  engine actor. The endpoint body itself is NIO-embedded; these helpers
//  were extracted from it precisely so this behavior is testable without
//  booting a server.
//

import Foundation
import Testing

@testable import OsaurusCore

struct HealthBatchDiagnosticsShapingTests {

    private func makeSnapshot(depthSummary: String?) -> BatchDiagnosticsSnapshot {
        BatchDiagnosticsSnapshot(
            pendingCount: 2,
            activeCount: 1,
            activeHighWatermark: 3,
            decodeSplitCount: 0,
            turboQuantCompressions: 4,
            isAcceptingRequests: true,
            nativeMTPModelCount: depthSummary?.isEmpty == false ? 1 : 0,
            nativeMTPDepthSummary: depthSummary,
            prefixHits: 7,
            prefixMisses: 5
        )
    }

    @Test func nil_snapshot_shapes_to_json_null() {
        let shaped = HTTPHandler.healthBatchDiagnosticsObject(nil)
        #expect(shaped is NSNull)
    }

    @Test func populated_snapshot_shapes_counters_and_depths() throws {
        let shaped = HTTPHandler.healthBatchDiagnosticsObject(makeSnapshot(depthSummary: "d2, d4"))
        let dict = try #require(shaped as? [String: Any])
        #expect(dict["pending"] as? Int == 2)
        #expect(dict["active"] as? Int == 1)
        #expect(dict["active_high_watermark"] as? Int == 3)
        #expect(dict["accepting_requests"] as? Bool == true)
        #expect(dict["native_mtp_depths"] as? String == "d2, d4")
        #expect(dict["prefix_hits"] as? Int == 7)
        #expect(dict["prefix_misses"] as? Int == 5)
        #expect(dict["turboquant_compressions"] as? Int == 4)
    }

    @Test func empty_depth_summary_emits_json_null_not_empty_string() throws {
        let shaped = HTTPHandler.healthBatchDiagnosticsObject(makeSnapshot(depthSummary: ""))
        let dict = try #require(shaped as? [String: Any])
        #expect(dict["native_mtp_depths"] is NSNull)
    }

    @Test func nil_depth_summary_emits_json_null() throws {
        let shaped = HTTPHandler.healthBatchDiagnosticsObject(makeSnapshot(depthSummary: nil))
        let dict = try #require(shaped as? [String: Any])
        #expect(dict["native_mtp_depths"] is NSNull)
    }

    @Test func deadline_race_returns_value_when_operation_is_fast() async {
        let value = await HTTPHandler.awaitWithDeadline(nanoseconds: 1_000_000_000) { 42 }
        #expect(value == 42)
    }

    @Test func deadline_race_returns_nil_when_operation_is_wedged() async {
        let start = Date()
        let value: Int? = await HTTPHandler.awaitWithDeadline(nanoseconds: 50_000_000) {
            // Simulate a fetch stuck behind a wedged engine actor.
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return 42
        }
        #expect(value == nil)
        // Must come back at the deadline, not after the wedged operation.
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
