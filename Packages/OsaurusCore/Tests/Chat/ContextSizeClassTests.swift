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

    /// Expected Foundation window/class on THIS device. The resolver now
    /// probes the real `SystemLanguageModel.contextSize` (back-deployed to
    /// macOS 26.0) instead of hard-coding 4096, so the test derives its
    /// expectation from the same probe rather than pinning a literal — that
    /// keeps it green on the 26.x baseline (4096 → `.tiny`) AND on 27.0+
    /// hardware (8192 → `.small`) while still catching a classification
    /// regression. The probe falls back to `tinyCeiling` when Foundation is
    /// unavailable (CI without the model), which lands on `.tiny`.
    private static var expectedFoundationCtx: Int {
        FoundationModelService.defaultModelContextSize ?? ContextSizeResolver.tinyCeiling
    }
    private static var expectedFoundationClass: ContextSizeClass {
        ContextSizeResolver.sizeClass(forContextLength: expectedFoundationCtx)
    }

    @Test("foundation canonical id matches the probed on-device window")
    func foundationIdMatchesProbe() {
        let info = ContextSizeResolver.resolve(modelId: "foundation")
        #expect(info.sizeClass == Self.expectedFoundationClass)
        #expect(info.contextLength == Self.expectedFoundationCtx)
        // Foundation always compacts: even at an 8K window it's a small
        // on-device model where verbose-prompt tokenization isn't worth it.
        #expect(info.prefersCompactPrompt)
    }

    @Test("default alias resolves identically to foundation")
    func defaultAliasMatchesFoundation() {
        let viaDefault = ContextSizeResolver.resolve(modelId: "default")
        #expect(viaDefault.sizeClass == Self.expectedFoundationClass)
        #expect(viaDefault.contextLength == Self.expectedFoundationCtx)
    }

    @Test("Foundation matching is case-insensitive")
    func foundationCasingMatches() {
        // Capitalised forms appear in persisted JSON (the migration
        // tests in ModelOverride exercise this exact path). The
        // resolver MUST keep matching them or the auto-disable
        // silently breaks for users who edited the config by hand.
        let expected = Self.expectedFoundationClass
        #expect(ContextSizeResolver.resolve(modelId: "Foundation").sizeClass == expected)
        #expect(ContextSizeResolver.resolve(modelId: "FOUNDATION").sizeClass == expected)
        #expect(ContextSizeResolver.resolve(modelId: "Default").sizeClass == expected)
    }

    @Test("foundation match wins even if ModelInfo would disagree")
    func foundationShortCircuitsBeforeModelInfo() {
        // Even though `ModelInfo.load(modelId: "foundation")` returns
        // nil today (no MLX config on disk for Apple's model), the
        // resolver does not need that branch to hit. If someone ever
        // ships a folder named "foundation" with a bigger context
        // length, the alias check still wins. Tests the ordering.
        let info = ContextSizeResolver.resolve(modelId: "foundation")
        #expect(info.sizeClass == Self.expectedFoundationClass)
        #expect(info.contextLength == Self.expectedFoundationCtx)
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

    // MARK: - Pure window→class mapping (device-independent)

    /// Boundary policy for `sizeClass(forContextLength:)` — the helper the
    /// Foundation probe and the MLX `config.json` path both route through.
    /// Pins the inclusive ceilings without an installed model so the
    /// 8192 → `.small` upgrade path (Foundation on 27.0+ hardware) is
    /// proven even though this device reports a 4096 window.
    @Test("sizeClass: tiny ceiling and one token past it")
    func classifyTinyBoundary() {
        #expect(ContextSizeResolver.sizeClass(forContextLength: 1) == .tiny)
        #expect(ContextSizeResolver.sizeClass(forContextLength: 4096) == .tiny)
        #expect(ContextSizeResolver.sizeClass(forContextLength: 4097) == .small)
    }

    @Test("sizeClass: small ceiling and one token past it")
    func classifySmallBoundary() {
        // 8192 is the documented Foundation window on macOS 27.0+ hardware:
        // it must land on `.small` so tools turn back on (memory stays off).
        #expect(ContextSizeResolver.sizeClass(forContextLength: 8192) == .small)
        #expect(ContextSizeResolver.sizeClass(forContextLength: 8193) == .normal)
        #expect(ContextSizeResolver.sizeClass(forContextLength: 131_072) == .normal)
    }

    @Test("an 8K Foundation window would enable tools but not memory")
    func smallFoundationWindowKeepsToolsEnablesMemoryOff() {
        // Documents the actual product effect of the probe-driven upgrade:
        // at the 8K window Foundation ships on 27.0+, the size class is
        // `.small`, whose disable predicates leave tools ON and memory OFF.
        let small = ContextSizeResolver.sizeClass(forContextLength: 8192)
        #expect(small == .small)
        #expect(small.disablesTools == false)
        #expect(small.disablesMemory)
    }
}
