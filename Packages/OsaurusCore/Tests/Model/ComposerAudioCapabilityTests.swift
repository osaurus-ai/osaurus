import Foundation
import Testing

@testable import OsaurusCore

/// The composer decided audio from the model NAME. The checkpoint-fact answer
/// already existed in `ModelMediaCapabilities.from(directory:modelId:)`, which
/// scans the safetensors index for `embed_audio.embedding_projection` —
/// nothing on the composer path reached it.
///
/// Live consequence, seen in the dev app on gemma-4 E2B-it-8bit (a bundle that
/// DOES carry that tensor): the attach panel read "Select files to attach
/// (image supported)" and every `.wav` row was greyed out, so an audio-capable
/// model could not be handed audio at all.
@Suite("composer audio capability comes from the checkpoint")
struct ComposerAudioCapabilityTests {

    /// The exact shape that shipped broken: a gemma-4 id that says nothing
    /// about audio, on a bundle whose weights carry it.
    @Test("a name that does not advertise audio still gains it from the weights")
    func checkpointFactAddsAudio() {
        let id = "OsaurusAI/gemma-4-E2B-it-8bit"

        let nameOnly = ModelMediaCapabilities.composerCapabilities(
            modelId: id,
            fallbackSupportsImages: true,
            localModelType: "gemma4",
            localHasAudioTensors: false)
        #expect(
            !nameOnly.supportsAudio,
            "guard the control: if the NAME alone already yielded audio this test proves nothing")

        let withCheckpoint = ModelMediaCapabilities.composerCapabilities(
            modelId: id,
            fallbackSupportsImages: true,
            localModelType: "gemma4",
            localHasAudioTensors: true)
        #expect(withCheckpoint.supportsAudio)
        #expect(withCheckpoint.supportsImage, "audio must not cost the image path")
    }

    /// The panel message and the allowlist are both built from `summary`, so
    /// the user-visible string is what actually gates attaching.
    @Test("the picker prompt names audio once the checkpoint proves it")
    func summaryNamesAudio() {
        let caps = ModelMediaCapabilities.composerCapabilities(
            modelId: "OsaurusAI/gemma-4-E2B-it-8bit",
            fallbackSupportsImages: true,
            localModelType: "gemma4",
            localHasAudioTensors: true)
        #expect(caps.summary.contains("audio"), "got \(caps.summary)")
    }

    /// A bundle with no audio tensors must stay unsupported — 26B-A4B ships no
    /// audio weights, so offering audio there would be a lie that fails at
    /// generation time rather than at the picker.
    @Test("no audio tensors means no audio, regardless of family")
    func absentTensorsStayUnsupported() {
        let caps = ModelMediaCapabilities.composerCapabilities(
            modelId: "OsaurusAI/gemma-4-26B-A4B-it-qat-JANG_4M",
            fallbackSupportsImages: true,
            localModelType: "gemma4",
            localHasAudioTensors: false)
        #expect(!caps.supportsAudio)
    }

    /// `withAudio` may only ADD. A name-based verdict cannot see weights, so
    /// letting it clear a proven capability would be strictly wrong.
    @Test("withAudio never removes an existing capability")
    func withAudioOnlyAdds() {
        #expect(ModelMediaCapabilities.Capabilities.omni.withAudio(false).supportsAudio)
        #expect(ModelMediaCapabilities.Capabilities.imageOnly.withAudio(true).supportsAudio)
        #expect(ModelMediaCapabilities.Capabilities.imageOnly.withAudio(true).supportsImage)
        #expect(!ModelMediaCapabilities.Capabilities.imageOnly.withAudio(false).supportsAudio)
    }
}
