//
//  EvalMTPControlTests.swift
//  OsaurusEvalsKitTests
//
//  Parsing and fail-closed verdicts for the `--mtp` control
//  (osaurus#2526). The verdict judges THREE evidence layers — request,
//  independent runtime resolution (load plan + per-request strategy), and
//  per-step token stats — because absent stats alone are ambiguous
//  ("not requested" and "requested but gate-excluded" both leave stats
//  nil). Configured depth and adaptive ACTIVE depth are distinct: only
//  the configured depth is enforced; adaptive downshifts never fail a row.
//

import Foundation
import Testing

@testable import OsaurusEvalsKit

struct EvalMTPControlTests {

    private func resolution(
        strategy: String, depth: Int? = nil,
        loadStatus: String? = nil, loadReason: String? = nil
    ) -> EvalMTPResolution {
        EvalMTPResolution(
            loadStatus: loadStatus, loadReason: loadReason,
            requestStrategy: strategy, requestConfiguredDepth: depth)
    }

    private var plainAR: EvalMTPResolution { resolution(strategy: "none") }
    private func nativeMTP(_ d: Int) -> EvalMTPResolution {
        resolution(
            strategy: "native_mtp:d\(d)·greedy-when-active", depth: d,
            loadStatus: "native_mtp:d\(d)")
    }

    @Test func parseAcceptsCanonicalValues() {
        #expect(EvalMTPControl.parse("off") == .off)
        #expect(EvalMTPControl.parse("auto") == .auto)
        #expect(EvalMTPControl.parse("d1") == .forcedDepth(1))
        #expect(EvalMTPControl.parse("D2") == .forcedDepth(2))
        #expect(EvalMTPControl.parse("d3") == .forcedDepth(3))
        #expect(EvalMTPControl.parse("on") == nil)
        #expect(EvalMTPControl.parse("d4") == nil)
        #expect(EvalMTPControl.parse("") == nil)
    }

    // MARK: off

    /// Off honored: resolution explicitly says plain AR and no step stats.
    @Test func offHonoredByExplicitNoneStrategy() {
        #expect(
            EvalMTPControlState.verdict(
                requested: .off, resolution: plainAR,
                tokenStepConfiguredDepths: [nil, nil]) == .honored)
    }

    /// Off with MISSING stats but a resolution that wrongly configured
    /// native MTP is a violation — the resolution evidence alone convicts.
    @Test func offViolatedByResolvedNativeMTPEvenWithoutStats() {
        let verdict = EvalMTPControlState.verdict(
            requested: .off, resolution: nativeMTP(2),
            tokenStepConfiguredDepths: [nil])
        guard case .violation(let message) = verdict else {
            Issue.record("expected violation, got \(verdict)")
            return
        }
        #expect(message.contains("requested off"))
        #expect(message.contains("native_mtp:d2"))
    }

    @Test func offViolatedByMTPStepStats() {
        let verdict = EvalMTPControlState.verdict(
            requested: .off, resolution: plainAR,
            tokenStepConfiguredDepths: [2])
        guard case .violation = verdict else {
            Issue.record("expected violation, got \(verdict)")
            return
        }
    }

    /// Off without captured resolution proves nothing — unverified, never
    /// a silent pass ("absent stats ≠ off").
    @Test func offWithoutResolutionIsUnverified() {
        let verdict = EvalMTPControlState.verdict(
            requested: .off, resolution: nil, tokenStepConfiguredDepths: [nil])
        guard case .unverified = verdict else {
            Issue.record("expected unverified, got \(verdict)")
            return
        }
    }

    // MARK: auto

    /// Auto resolved to plain AR: honored, and the resolution is what the
    /// report records (auto enforces nothing but must SAY what resolved).
    @Test func autoResolvedOffIsHonored() {
        #expect(
            EvalMTPControlState.verdict(
                requested: .auto, resolution: plainAR,
                tokenStepConfiguredDepths: [nil]) == .honored)
    }

    /// Auto resolved to native MTP at any depth: honored.
    @Test func autoResolvedDepthIsHonored() {
        for d in 1...3 {
            #expect(
                EvalMTPControlState.verdict(
                    requested: .auto, resolution: nativeMTP(d),
                    tokenStepConfiguredDepths: [d]) == .honored)
        }
    }

    /// Auto without captured resolution cannot say what it resolved to.
    @Test func autoWithoutResolutionIsUnverified() {
        let verdict = EvalMTPControlState.verdict(
            requested: .auto, resolution: nil, tokenStepConfiguredDepths: [nil])
        guard case .unverified = verdict else {
            Issue.record("expected unverified, got \(verdict)")
            return
        }
    }

    // MARK: forced depth

    @Test func forcedDepthHonoredEndToEnd() {
        #expect(
            EvalMTPControlState.verdict(
                requested: .forcedDepth(2), resolution: nativeMTP(2),
                tokenStepConfiguredDepths: [2, 2]) == .honored)
    }

    /// Blocked before load (no MTP tensors / gate): the resolution never
    /// reaches native_mtp → explicit violation naming the load reason.
    @Test func forcedDepthBlockedAtLoadIsExplicitError() {
        let blocked = resolution(
            strategy: "none", loadStatus: nil,
            loadReason: "bundle has no MTP tensors")
        let verdict = EvalMTPControlState.verdict(
            requested: .forcedDepth(2), resolution: blocked,
            tokenStepConfiguredDepths: [nil])
        guard case .violation(let message) = verdict else {
            Issue.record("expected violation, got \(verdict)")
            return
        }
        #expect(message.contains("requested d2"))
        #expect(message.contains("no MTP tensors"))
    }

    /// Configured-depth mismatch (engine cap / policy override) fails —
    /// and the message speaks of CONFIGURED depth, not adaptive behavior.
    @Test func forcedConfiguredDepthMismatchIsViolation() {
        let verdict = EvalMTPControlState.verdict(
            requested: .forcedDepth(3), resolution: nativeMTP(3),
            tokenStepConfiguredDepths: [2])
        guard case .violation(let message) = verdict else {
            Issue.record("expected violation, got \(verdict)")
            return
        }
        #expect(message.contains("configured depth"))
        #expect(message.contains("[2]"))
    }

    /// Adaptive ACTIVE-depth downshift never fails a row: the verdict only
    /// sees configured depths, and a step whose stats report configured d3
    /// (while adaptively running active d1) is honored.
    @Test func forcedDepthAdaptiveDownshiftDoesNotFail() {
        #expect(
            EvalMTPControlState.verdict(
                requested: .forcedDepth(3), resolution: nativeMTP(3),
                tokenStepConfiguredDepths: [3, 3]) == .honored)
    }

    /// A passing row with correct resolution but NO token-producing
    /// evidence is unverified — configured-depth execution is unproven.
    @Test func forcedDepthWithoutDecodeEvidenceIsUnverified() {
        let verdict = EvalMTPControlState.verdict(
            requested: .forcedDepth(2), resolution: nativeMTP(2),
            tokenStepConfiguredDepths: [])
        guard case .unverified(let message) = verdict else {
            Issue.record("expected unverified, got \(verdict)")
            return
        }
        #expect(message.contains("no token-level decode evidence"))
    }

    /// A token-producing step that ran WITHOUT native MTP under a forced
    /// depth (request-level gate exclusion) is a violation.
    @Test func forcedDepthStepGateExclusionIsViolation() {
        let verdict = EvalMTPControlState.verdict(
            requested: .forcedDepth(2), resolution: nativeMTP(2),
            tokenStepConfiguredDepths: [2, nil])
        guard case .violation(let message) = verdict else {
            Issue.record("expected violation, got \(verdict)")
            return
        }
        #expect(message.contains("without native MTP"))
    }

    @Test func forcedDepthWithoutResolutionIsUnverified() {
        let verdict = EvalMTPControlState.verdict(
            requested: .forcedDepth(1), resolution: nil,
            tokenStepConfiguredDepths: [1])
        guard case .unverified = verdict else {
            Issue.record("expected unverified, got \(verdict)")
            return
        }
    }
}
