import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import Testing

@testable import OsaurusCore

/// Everything measurable about the vision path checks out — weights, channel
/// order, normalization, tower separation — yet the model names a solid red
/// field "green". The last unmeasured link is geometry: how many patches the
/// resize actually produces, and whether the number of `<|patch|>` placeholders
/// in the prompt matches the number of vision tokens the tower will emit.
///
/// A mismatch there is silent. Too few placeholders truncates the image; a
/// degenerate grid means the model is shown a handful of patches and answers
/// from the text prior, which is exactly what a constant "green" looks like.
@Suite("Muse Glimmer image geometry")
struct MuseGlimmerImageGeometryTests {

    static let bundle: URL = {
        let name = ProcessInfo.processInfo.environment["MUSE_VL_BUNDLE"]
            ?? "Muse-Glimmer-30B-JANG_4M"
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("models/JANGQ-AI/\(name)")
    }()

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["MUSE_VL_LIVE"] == "1"
            && FileManager.default.fileExists(
                atPath: bundle.appendingPathComponent("config.json").path)
    }

    @Test("placeholder count matches the vision token count", .enabled(if: enabled))
    func geometryIsConsistent() async throws {
        let context = try await MLXVLM.VLMModelFactory.shared.load(
            from: Self.bundle, using: SwiftTransformersTokenizerLoader())

        for path in ["/tmp/raptorproof/solid-red.png", "/tmp/raptorproof/vl-bands.png"] {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let userInput = UserInput(
                prompt: "What colour is this?",
                images: [.ciImage(CIImage(contentsOf: URL(fileURLWithPath: path))!)],
                additionalContext: ["reasoning_strength": "low"])
            let input = try await context.processor.prepare(input: userInput)

            let name = (path as NSString).lastPathComponent
            guard let image = input.image else {
                Issue.record("\(name): no image survived prepare")
                continue
            }
            let frames = image.frames ?? []
            let pixels = image.pixels
            let tokens = input.text.tokens.asArray(Int32.self)
            let patchTokens = tokens.filter { $0 == 200_092 }.count

            // Each frame contributes t*h*w patches, merged 2x2 into vision tokens.
            let merge = 2
            let rawPatches = frames.reduce(0) { $0 + $1.t * $1.h * $1.w }
            let visionTokens = rawPatches / (merge * merge)

            print("[geom] \(name)")
            print("[geom]   frames=\(frames.map { "(\($0.t),\($0.h),\($0.w))" }.joined())")
            print("[geom]   pixels shape=\(pixels.shape)")
            print("[geom]   raw patches=\(rawPatches) → vision tokens=\(visionTokens)")
            print("[geom]   <|patch|> placeholders in prompt=\(patchTokens)")
            print("[geom]   total prompt tokens=\(tokens.count)")

            #expect(patchTokens == visionTokens,
                "\(name): \(patchTokens) placeholders but \(visionTokens) vision tokens — the scatter is misaligned")
            // A handful of patches means the model is effectively blind even
            // though every tensor is well-formed.
            #expect(visionTokens >= 16,
                "\(name): only \(visionTokens) vision tokens — the resize collapsed the image")
        }
    }
}
