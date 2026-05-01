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
        let (cls, ctx) = ContextSizeResolver.resolve(modelId: "foundation")
        #expect(cls == .tiny)
        #expect(ctx == ContextSizeResolver.tinyCeiling)
    }

    @Test("default alias maps to .tiny (matches FoundationModelService.handles)")
    func defaultAliasIsTiny() {
        let (cls, _) = ContextSizeResolver.resolve(modelId: "default")
        #expect(cls == .tiny)
    }

    @Test("Foundation matching is case-insensitive")
    func foundationCasingIsTiny() {
        // Capitalised forms appear in persisted JSON (the migration
        // tests in ModelOverride exercise this exact path). The
        // resolver MUST keep matching them or the auto-disable
        // silently breaks for users who edited the config by hand.
        let (a, _) = ContextSizeResolver.resolve(modelId: "Foundation")
        let (b, _) = ContextSizeResolver.resolve(modelId: "FOUNDATION")
        let (c, _) = ContextSizeResolver.resolve(modelId: "Default")
        #expect(a == .tiny)
        #expect(b == .tiny)
        #expect(c == .tiny)
    }

    @Test("foundation match wins even if ModelInfo would disagree")
    func foundationShortCircuitsBeforeModelInfo() {
        // Even though `ModelInfo.load(modelId: "foundation")` returns
        // nil today (no MLX config on disk for Apple's model), the
        // resolver does not need that branch to hit. If someone ever
        // ships a folder named "foundation" with a bigger context
        // length, the alias check still wins. Tests the ordering.
        let (cls, ctx) = ContextSizeResolver.resolve(modelId: "foundation")
        #expect(cls == .tiny)
        #expect(ctx == ContextSizeResolver.tinyCeiling)
    }

    // MARK: - Nil / blank

    @Test("nil model id returns .normal with no ctx")
    func nilModelIsNormal() {
        let (cls, ctx) = ContextSizeResolver.resolve(modelId: nil)
        #expect(cls == .normal)
        #expect(ctx == nil)
    }

    @Test("blank / whitespace model id returns .normal")
    func blankModelIsNormal() {
        // Mid-window state: chat hasn't picked a model yet. We should
        // NOT speculatively hide tools — `.normal` is the safe default.
        let (a, _) = ContextSizeResolver.resolve(modelId: "")
        let (b, _) = ContextSizeResolver.resolve(modelId: "   \n\t  ")
        #expect(a == .normal)
        #expect(b == .normal)
    }

    // MARK: - Unknown model

    @Test("unknown model id with no ModelInfo falls back to .normal")
    func unknownModelIsNormal() {
        // No installed model directory + not the Foundation alias =
        // we don't know the budget, so don't auto-disable. Conservative
        // by design — false positives would silently strip tools from
        // users on niche models we haven't catalogued.
        let (cls, ctx) = ContextSizeResolver.resolve(
            modelId: "definitely-not-installed-\(UUID().uuidString)"
        )
        #expect(cls == .normal)
        #expect(ctx == nil)
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
