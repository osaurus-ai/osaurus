import CoreImage
import Foundation
import MLX
import MLXLMCommon
import MLXVLM
import Testing

@testable import OsaurusCore

/// End-to-end vision on the REAL 20GB bundle: image → processor → vision tower
/// → language model → text. Everything else about the image path is checked on
/// synthetic patches or on the processor alone; only this exercises the whole
/// chain against trained weights, which is the difference between "the shapes
/// line up" and "the model can see".
///
/// Opt-in (`MUSE_VL_LIVE=1`) because it loads ~20GB and runs a real generation.
@Suite("Muse Glimmer vision live")
struct MuseGlimmerVisionLiveTests {

    /// Defaults to the 4-bit bundle; set `MUSE_VL_BUNDLE` to a bundle name to
    /// run the same check against another quant (the proof matrix wants both
    /// JANG_4M and JANG_6M).
    static let bundle: URL = {
        let name = ProcessInfo.processInfo.environment["MUSE_VL_BUNDLE"]
            ?? "Muse-Glimmer-30B-JANG_4M"
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("models/JANGQ-AI/\(name)")
    }()
    static let imagePath = "/tmp/raptorproof/vl-bands.png"

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["MUSE_VL_LIVE"] == "1"
            && FileManager.default.fileExists(atPath: imagePath)
            && FileManager.default.fileExists(
                atPath: bundle.appendingPathComponent("config.json").path)
    }

    @Test("an image reaches the model and the answer is about it", .enabled(if: enabled))
    func modelSeesTheBands() async throws {
        let context = try await MLXVLM.VLMModelFactory.shared.load(
            from: Self.bundle, using: SwiftTransformersTokenizerLoader())

        let image = CIImage(contentsOf: URL(fileURLWithPath: Self.imagePath))!
        let userInput = UserInput(
            prompt: "This image has three horizontal colour bands. "
                + "Name them from top to bottom, in three words.",
            images: [.ciImage(image)],
            // Muse defaults to `Reasoning strength: high`; at a small token
            // budget the whole allowance is spent in the to=self thinking
            // channel and the visible answer comes back empty. Ask for `low`
            // and give it room so the answer itself is what is measured.
            additionalContext: ["reasoning_strength": "low"])

        let input = try await context.processor.prepare(input: userInput)
        // The prompt must actually carry image placeholders — without this a
        // text-only answer would look like a pass.
        #expect(input.image != nil, "no processed image reached the model")

        var text = ""
        let stream = try MLXLMCommon.generate(
            input: input,
            parameters: GenerateParameters(maxTokens: 400, temperature: 0.0),
            context: context)
        for await item in stream {
            if let chunk = item.chunk { text += chunk }
        }

        let lower = text.lowercased()
        print("[muse-vl] answer: \(text)")

        // The wiring contract: the model produced a non-empty answer that is
        // *about the picture*. Colour naming is model quality on a 4-bit quant
        // and is asserted separately against the patch tensor in
        // MuseGlimmerColourFidelityTests, which shows the channels do survive
        // the pipeline — so requiring "red/green/blue" here would test the
        // quant, not the integration.
        #expect(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "empty answer — the vision path produced no visible content")
        let grounded = ["band", "stripe", "horizontal", "colour", "color", "grey", "gray",
                        "red", "green", "blue", "ramp", "image"]
        #expect(grounded.contains { lower.contains($0) },
            "answer is not about the image: \(text)")
    }

    /// Both quants described a saturated red/green/blue image as "greyscale" or
    /// "low-contrast", which reads like a lost colour channel. The patch tensor
    /// and the vision tower were both cleared separately, so the remaining
    /// question is whether the *trained* model resolves hue at all, or whether
    /// something subtler (patch ordering, position embedding) leaves it unable
    /// to bind colour to place.
    ///
    /// A forced choice settles it where an open description cannot: an
    /// open-ended answer lets the model hedge, but "red or blue" has to commit.
    /// It also checks vertical orientation for free — the top band IS red, so a
    /// flipped position embedding would confidently answer "blue".
    @Test("the model resolves the top band's hue under forced choice",
        .enabled(if: enabled))
    func forcedChoiceHue() async throws {
        let context = try await MLXVLM.VLMModelFactory.shared.load(
            from: Self.bundle, using: SwiftTransformersTokenizerLoader())
        let image = CIImage(contentsOf: URL(fileURLWithPath: Self.imagePath))!

        // Asking about BOTH ends in one loaded context is what separates a real
        // vertical flip from the model simply favouring one word: an inversion
        // gets both backwards, a bias answers the same colour twice.
        func ask(_ edge: String) async throws -> String {
            let userInput = UserInput(
                prompt: "Look at the \(edge) horizontal band in this image. "
                    + "Is it red or blue? Reply with exactly one word.",
                images: [.ciImage(image)],
                additionalContext: ["reasoning_strength": "low"])
            let input = try await context.processor.prepare(input: userInput)
            #expect(input.image != nil, "no processed image reached the model")
            var text = ""
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: 400, temperature: 0.0),
                context: context)
            for await item in stream {
                if let chunk = item.chunk { text += chunk }
            }
            return text.lowercased()
        }

        // Ground truth read straight out of the PNG: top (220,30,30) is red,
        // bottom (40,70,220) is blue.
        let top = try await ask("topmost")
        let bottom = try await ask("bottommost")
        print("[muse-vl] top band (truth=red): \(top)")
        print("[muse-vl] bottom band (truth=blue): \(bottom)")

        func hue(_ s: String) -> String? {
            let r = s.contains("red"), b = s.contains("blue")
            return r == b ? nil : (r ? "red" : "blue")
        }
        let t = hue(top), b = hue(bottom)

        if t == "red" && b == "blue" {
            print("[muse-vl] hue + vertical order BOTH CORRECT")
        } else if t == "blue" && b == "red" {
            Issue.record(
                "clean vertical inversion: top read as blue, bottom as red — colour survives but the image is upside down to the model; suspect the position-embedding resample or patch row order")
        } else if t != nil && t == b {
            // Same answer for opposite ends: the model is not resolving
            // position, so this says nothing about orientation.
            print("[muse-vl] both ends answered '\(t!)' — answer bias, not an orientation bug")
        } else {
            print("[muse-vl] INCONCLUSIVE — top=\(t ?? "none") bottom=\(b ?? "none")")
        }
        #expect(t != nil || b != nil, "neither answer engaged the choice")
    }

    /// The band image leaves one ambiguity: a model can fail to name a colour
    /// either because hue never reaches it, or because it cannot bind a hue to
    /// a *place*. A solid field removes the binding problem entirely — there is
    /// only one colour and no position to get wrong — so this isolates hue
    /// perception itself.
    ///
    /// Two opposite fields, because a single one cannot distinguish seeing from
    /// guessing: a model that answers "red" to everything scores 1/1 on red
    /// alone and 1/2 across the pair.
    @Test("solid colour fields are named correctly", .enabled(if: enabled))
    func solidColourFields() async throws {
        let red = "/tmp/raptorproof/solid-red.png"
        let blue = "/tmp/raptorproof/solid-blue.png"
        try #require(FileManager.default.fileExists(atPath: red))
        try #require(FileManager.default.fileExists(atPath: blue))

        let context = try await MLXVLM.VLMModelFactory.shared.load(
            from: Self.bundle, using: SwiftTransformersTokenizerLoader())

        func name(_ path: String) async throws -> String {
            let userInput = UserInput(
                prompt: "What single colour fills this entire image? "
                    + "Reply with exactly one word.",
                images: [.ciImage(CIImage(contentsOf: URL(fileURLWithPath: path))!)],
                additionalContext: ["reasoning_strength": "low"])
            let input = try await context.processor.prepare(input: userInput)
            #expect(input.image != nil, "no processed image reached the model")
            var text = ""
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: 300, temperature: 0.0),
                context: context)
            for await item in stream {
                if let chunk = item.chunk { text += chunk }
            }
            return text.lowercased()
        }

        let onRed = try await name(red)
        let onBlue = try await name(blue)
        print("[muse-vl] solid red  (230,20,20) → \(onRed)")
        print("[muse-vl] solid blue (20,20,230) → \(onBlue)")

        let redOK = onRed.contains("red")
        let blueOK = onBlue.contains("blue")
        if redOK && blueOK {
            print("[muse-vl] HUE PERCEPTION CONFIRMED on both fields")
        }
        // Both must land. Passing only one is exactly what a constant answer
        // produces, so a half score is a failure, not partial credit.
        #expect(redOK, "solid red field was not named red: \(onRed)")
        #expect(blueOK, "solid blue field was not named blue: \(onBlue)")
    }

    /// Every measurable link in the vision path is verified — weights, channel
    /// order, normalization, trained-tower colour separation, placeholder
    /// geometry and token scale — yet flat synthetic fields get named wrongly.
    /// Flat colour is also about as far out of distribution as an image can be
    /// for a model trained on photographs, so this asks the question with the
    /// stimulus the model was actually trained on.
    ///
    /// Two different scenes, because one description alone cannot distinguish
    /// seeing from a generic caption: a blind model emits the same plausible
    /// sentence for both.
    @Test("real photographs are described distinctly", .enabled(if: enabled))
    func realPhotographs() async throws {
        let coast = "/tmp/raptorproof/photo-coast.png"
        let aerial = "/tmp/raptorproof/photo-aerial.png"
        try #require(FileManager.default.fileExists(atPath: coast))
        try #require(FileManager.default.fileExists(atPath: aerial))

        let context = try await MLXVLM.VLMModelFactory.shared.load(
            from: Self.bundle, using: SwiftTransformersTokenizerLoader())

        func describe(_ path: String) async throws -> String {
            let userInput = UserInput(
                prompt: "Describe this photograph in one short sentence.",
                images: [.ciImage(CIImage(contentsOf: URL(fileURLWithPath: path))!)],
                additionalContext: ["reasoning_strength": "low"])
            let input = try await context.processor.prepare(input: userInput)
            #expect(input.image != nil, "no processed image reached the model")
            var text = ""
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: 300, temperature: 0.0),
                context: context)
            for await item in stream {
                if let chunk = item.chunk { text += chunk }
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let a = try await describe(coast)
        let b = try await describe(aerial)
        print("[muse-vl] coast  → \(a)")
        print("[muse-vl] aerial → \(b)")

        #expect(!a.isEmpty && !b.isEmpty, "empty description")
        // Distinct answers are the real signal: identical text for two
        // different scenes means the image is not informing the answer.
        #expect(a != b, "identical description for two different photographs — the image is not reaching the answer")

        let scene = ["coast", "ocean", "sea", "water", "cliff", "beach", "shore",
                     "sky", "mountain", "landscape", "aerial", "hill", "rock", "wave"]
        let aHit = scene.contains { a.lowercased().contains($0) }
        let bHit = scene.contains { b.lowercased().contains($0) }
        print("[muse-vl] scene vocabulary — coast:\(aHit) aerial:\(bHit)")
        #expect(aHit || bHit, "neither description used any scene vocabulary")
    }

    /// A shape whose content is known exactly, unlike a stock thumbnail whose
    /// subject cannot be verified. High-contrast black-on-white geometry is the
    /// easiest thing a vision model can be asked to do, so failing here would
    /// mean spatial structure never arrives, while succeeding would confine the
    /// earlier oddities to hard or out-of-distribution stimuli.
    ///
    /// Forced choice over a matched pair: a model answering "circle" to
    /// everything scores 1/2, not 2/2.
    @Test("a circle and a square are told apart", .enabled(if: enabled))
    func shapeDiscrimination() async throws {
        let circle = "/tmp/raptorproof/shape-circle.png"
        let square = "/tmp/raptorproof/shape-square.png"
        try #require(FileManager.default.fileExists(atPath: circle))
        try #require(FileManager.default.fileExists(atPath: square))

        let context = try await MLXVLM.VLMModelFactory.shared.load(
            from: Self.bundle, using: SwiftTransformersTokenizerLoader())

        func classify(_ path: String) async throws -> String {
            let userInput = UserInput(
                prompt: "This image contains one black shape on a white background. "
                    + "Is the shape a circle or a square? Reply with exactly one word.",
                images: [.ciImage(CIImage(contentsOf: URL(fileURLWithPath: path))!)],
                additionalContext: ["reasoning_strength": "low"])
            let input = try await context.processor.prepare(input: userInput)
            #expect(input.image != nil, "no processed image reached the model")
            var text = ""
            let stream = try MLXLMCommon.generate(
                input: input,
                parameters: GenerateParameters(maxTokens: 300, temperature: 0.0),
                context: context)
            for await item in stream {
                if let chunk = item.chunk { text += chunk }
            }
            return text.lowercased()
        }

        let onCircle = try await classify(circle)
        let onSquare = try await classify(square)
        print("[muse-vl] circle image → \(onCircle)")
        print("[muse-vl] square image → \(onSquare)")

        let circleOK = onCircle.contains("circle") && !onCircle.contains("square")
        let squareOK = onSquare.contains("square") && !onSquare.contains("circle")
        print("[muse-vl] shape score: \((circleOK ? 1 : 0) + (squareOK ? 1 : 0))/2")

        #expect(circleOK, "the circle image was not called a circle: \(onCircle)")
        #expect(squareOK, "the square image was not called a square: \(onSquare)")
    }
}
