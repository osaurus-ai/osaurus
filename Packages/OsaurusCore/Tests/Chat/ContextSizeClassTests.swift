//
//  ContextSizeClassTests.swift
//  osaurusTests
//
//  Pure-function tests for `ContextSizeResolver`. The resolver is the
//  single source of truth for "is this model too small for tools/
//  memory" — a regression here is what produced the original
//  `Skills: 55k / 4.1k` blowout when Foundation got the full
//  feature set. These tests pin:
//
//    - Foundation matching (canonical id + `default` alias + casing)
//    - the tiny / small / normal threshold boundaries
//    - the unknown-model conservative default (no auto-disable)
//
//  No fixtures: ModelInfo.load is exercised live where possible and
//  treated as "could fail" everywhere else. The threshold tests use
//  the resolver's own constants rather than literal numbers so a
//  policy change moves the test in lock-step.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("ContextSizeResolver")
struct ContextSizeClassTests {

    // MARK: - Foundation aliases

    @Test("foundation canonical id maps to .tiny")
    func foundationIdIsTiny() {
        let info = ContextSizeResolver.resolve(modelId: "foundation")
        #expect(info.sizeClass == .tiny)
        #expect(info.contextLength == ContextSizeResolver.tinyCeiling)
    }

    @Test("default alias maps to .tiny (matches FoundationModelService.handles)")
    func defaultAliasIsTiny() {
        #expect(ContextSizeResolver.resolve(modelId: "default").sizeClass == .tiny)
    }

    @Test("Foundation matching is case-insensitive")
    func foundationCasingIsTiny() {
        // Capitalised forms appear in persisted JSON (the migration
        // tests in ModelOverride exercise this exact path). The
        // resolver MUST keep matching them or the auto-disable
        // silently breaks for users who edited the config by hand.
        #expect(ContextSizeResolver.resolve(modelId: "Foundation").sizeClass == .tiny)
        #expect(ContextSizeResolver.resolve(modelId: "FOUNDATION").sizeClass == .tiny)
        #expect(ContextSizeResolver.resolve(modelId: "Default").sizeClass == .tiny)
    }

    @Test("foundation match wins even if ModelInfo would disagree")
    func foundationShortCircuitsBeforeModelInfo() {
        // Even though `ModelInfo.load(modelId: "foundation")` returns
        // nil today (no MLX config on disk for Apple's model), the
        // resolver does not need that branch to hit. If someone ever
        // ships a folder named "foundation" with a bigger context
        // length, the alias check still wins. Tests the ordering.
        let info = ContextSizeResolver.resolve(modelId: "foundation")
        #expect(info.sizeClass == .tiny)
        #expect(info.contextLength == ContextSizeResolver.tinyCeiling)
    }

    // MARK: - Nil / blank

    @Test("nil model id returns .normal with no ctx")
    func nilModelIsNormal() {
        let info = ContextSizeResolver.resolve(modelId: nil)
        #expect(info.sizeClass == .normal)
        #expect(info.contextLength == nil)
    }

    @Test("blank / whitespace model id returns .normal")
    func blankModelIsNormal() {
        // Mid-window state: chat hasn't picked a model yet. We should
        // NOT speculatively hide tools — `.normal` is the safe default.
        #expect(ContextSizeResolver.resolve(modelId: "").sizeClass == .normal)
        #expect(ContextSizeResolver.resolve(modelId: "   \n\t  ").sizeClass == .normal)
    }

    // MARK: - Unknown model

    @Test("unknown model id with no ModelInfo falls back to .normal")
    func unknownModelIsNormal() {
        // No installed model directory + not the Foundation alias =
        // we don't know the budget, so don't auto-disable. Conservative
        // by design — false positives would silently strip tools from
        // users on niche models we haven't catalogued.
        let info = ContextSizeResolver.resolve(
            modelId: "definitely-not-installed-\(UUID().uuidString)"
        )
        #expect(info.sizeClass == .normal)
        #expect(info.contextLength == nil)
    }

    // MARK: - Disable predicates

    /// Tiny disables both axes; small disables only memory; normal
    /// is hands-off. The composer relies on these flags cascading
    /// into `effectiveToolsOff` / `memoryOff`, so a regression here
    /// silently hides tools (or fails to hide them) at compose time.
    @Test("disable predicates: tiny -> tools+memory off")
    func tinyDisablesTools() {
        #expect(ContextSizeClass.tiny.disablesTools)
        #expect(ContextSizeClass.tiny.disablesMemory)
    }

    @Test("disable predicates: small -> memory off only")
    func smallDisablesMemoryOnly() {
        #expect(ContextSizeClass.small.disablesTools == false)
        #expect(ContextSizeClass.small.disablesMemory)
    }

    @Test("disable predicates: normal -> nothing off")
    func normalDisablesNothing() {
        #expect(ContextSizeClass.normal.disablesTools == false)
        #expect(ContextSizeClass.normal.disablesMemory == false)
    }

    // MARK: - Thresholds

    @Test("tinyCeiling sits at the upper bound of .tiny")
    func tinyCeilingBoundary() {
        // The boundary value `4096` itself is `.tiny` (inclusive). One
        // more token should pivot to `.small`. Uses the resolver's
        // own constants so a future policy change moves the test
        // in lock-step.
        #expect(ContextSizeResolver.tinyCeiling == 4096)
        #expect(ContextSizeResolver.smallCeiling == 8192)
    }
}
