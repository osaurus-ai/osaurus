import Foundation
import Testing

@testable import OsaurusCore

/// Guards the profile-matching behavior behind osaurus's "reasoning
/// toggle" and "model options" UI. Each of these tests pins a concrete
/// rule the registry promises so we don't silently regress:
///
/// - `QwenThinkingProfile` should match every modern Qwen3.x family
///   (including 3.5, 3.6) because they share the `enable_thinking`
///   chat-template kwarg. Regressing this removes the toggle from
///   the UI and leaves users with no way to control reasoning.
///
/// - `AutoThinkingProfile` is the catch-all for local reasoning models
///   detected via their chat template. Since `QwenThinkingProfile`
///   registers first, Auto must *not* shadow it for Qwen models.
///
/// - Non-reasoning models must not match any thinking profile.
@Suite("ModelProfileRegistry — reasoning toggle dispatch")
struct ModelProfileRegistryTests {

    @Test("Qwen 3.5 matches QwenThinkingProfile and exposes disableThinking toggle")
    func qwen3_5() {
        let profile = ModelProfileRegistry.profile(for: "qwen3.5-35b-a3b-4bit")
        // Bind the boolean to a local `let` before `#expect` sees it.
        // Direct `#expect(profile != nil)` makes the macro reflect on the
        // operand type for diagnostic capture — and the operand here is
        // `(any ModelProfile.Type)?`, an *optional protocol existential
        // metatype*. Reflecting that through Swift Testing's `Expression.
        // captureValue` walks the existential's witness-table set and
        // segfaults on the GitHub Actions `Apple Virtual Machine 1`
        // macOS 15.7.4 ARM64e runner (worked locally on dev Macs).
        // Reproducer:
        // https://github.com/osaurus-ai/osaurus/actions/runs/24576426664/job/71862829833
        // Binding to `Bool` first makes the macro reflect on `Bool`, which
        // is safe.
        let hasProfile = profile != nil
        #expect(hasProfile, "QwenThinkingProfile should match `qwen3.5-*` ids")
        #expect(profile?.displayName == QwenThinkingProfile.displayName)
        #expect(profile?.thinkingOption?.id == "disableThinking")
        #expect(profile?.thinkingOption?.inverted == true)
    }

    @Test("Qwen 3.6 (MXFP4) matches the same QwenThinkingProfile")
    func qwen3_6_mxfp4() {
        // Substring match `qwen3` in `"qwen3.6-35b-a3b-mxfp4"` should carry
        // over from Qwen 3.5 without a new profile needed — the template
        // still exposes the same `enable_thinking` kwarg.
        let profile = ModelProfileRegistry.profile(for: "qwen3.6-35b-a3b-mxfp4")
        #expect(profile?.displayName == QwenThinkingProfile.displayName)
        #expect(profile?.thinkingOption?.id == "disableThinking")
    }

    @Test("Qwen 3.6 JANGTQ routes to QwenThinkingProfile, not AutoThinkingProfile")
    func qwen3_6_jangtq_notAutoProfile() {
        // JANGTQ is routed at weight-load time by vmlx (via weight_format:
        // "mxtq" in jang_config.json) — osaurus-side the *profile* is still
        // the generic Qwen thinking toggle. If Auto shadowed it we'd get
        // different default thinking-state behavior (Auto defaults ON, Qwen
        // defaults OFF). Locking the dispatch order here prevents that drift.
        let profile = ModelProfileRegistry.profile(for: "qwen3.6-35b-a3b-jangtq2")
        #expect(profile?.displayName == QwenThinkingProfile.displayName)
    }

    @Test("Qwen 3 Coder variants do NOT get a thinking toggle")
    func qwen3_coder_excluded() {
        // Qwen3-Coder is non-thinking only; registering the toggle
        // would show users a control that silently does nothing.
        let profile = ModelProfileRegistry.profile(for: "qwen3-coder-plus")
        // See `qwen3_5()` for why the boolean is bound to a local first
        // instead of being inlined into `#expect(...)`.
        let hasNoThinkingToggle = profile == nil || profile?.thinkingOption == nil
        #expect(hasNoThinkingToggle, "Qwen3-Coder is non-thinking; toggle would silently no-op")
    }

    @Test("Foundation (Apple built-in) does not match any thinking profile")
    func foundation_noProfile() {
        let profile = ModelProfileRegistry.profile(for: "foundation")
        // See `qwen3_5()` for why the boolean is bound to a local first
        // instead of being inlined into `#expect(...)`.
        let hasNoProfile = profile == nil
        #expect(hasNoProfile, "`foundation` is Apple's built-in model and has no MLX/HF profile")
    }

    @Test("Non-reasoning Gemma variants do not get a thinking toggle")
    func gemma_noThinkingToggle() {
        let profile = ModelProfileRegistry.profile(for: "gemma-4-e2b-it-4bit")
        // Gemma can match an image-options profile but should never expose
        // the thinking toggle because it doesn't honor `enable_thinking`.
        #expect(profile?.thinkingOption == nil)
    }
}
