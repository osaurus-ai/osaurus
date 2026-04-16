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
        #expect(profile != nil)
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
        #expect(profile == nil || profile?.thinkingOption == nil)
    }

    @Test("Foundation (Apple built-in) does not match any thinking profile")
    func foundation_noProfile() {
        let profile = ModelProfileRegistry.profile(for: "foundation")
        #expect(profile == nil)
    }

    @Test("Non-reasoning Gemma variants do not get a thinking toggle")
    func gemma_noThinkingToggle() {
        let profile = ModelProfileRegistry.profile(for: "gemma-4-e2b-it-4bit")
        // Gemma can match an image-options profile but should never expose
        // the thinking toggle because it doesn't honor `enable_thinking`.
        #expect(profile?.thinkingOption == nil)
    }
}
