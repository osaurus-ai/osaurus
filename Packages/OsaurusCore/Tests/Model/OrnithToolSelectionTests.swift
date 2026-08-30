import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing

@testable import OsaurusCore

/// Issue #2327: Ornith-1.0-9B-JANG_4M calls tools unreliably — both directions,
/// hallucinating instead of calling an available tool and (on Raptor) calling
/// `osaurus_help` for a plain computer-science question. The parser is already
/// cleared, so this asks whether the *model* picks correctly, and whether the
/// quantization is what costs it.
///
/// Two prompts, opposite correct answers, so a model that always calls or never
/// calls scores 1/2 rather than looking right on one of them. Run against both
/// quants of the same weights: a gap between them is quantization damage, and
/// the same failure in both points at prompt framing instead.
@Suite("Ornith tool selection")
struct OrnithToolSelectionTests {

    static func bundle(_ name: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("models/JANGQ-AI/\(name)")
    }

    /// Opt-in, because running this loads ~9 GB of weights twice.
    ///
    /// ```
    /// swift test --filter OrnithToolSelection                      # ORNITH_TOOLS=1
    /// xcodebuild test -only-testing:OsaurusCoreTests/OrnithToolSelectionTests
    ///                                                              # TEST_RUNNER_ORNITH_TOOLS=1
    /// ```
    ///
    /// The two spellings are not interchangeable. `xcodebuild` runs tests in a
    /// separate `xctest` process that does **not** inherit the invoking shell's
    /// environment; only variables prefixed `TEST_RUNNER_` are forwarded (with
    /// the prefix stripped). Passing the bare `ORNITH_TOOLS=1` there leaves this
    /// false, the case is **skipped**, and the run still reports
    /// `** TEST SUCCEEDED **` — a green result that measured nothing. Checking
    /// both is cheap and turns that silent skip into a visible one.
    static var enabled: Bool {
        let env = ProcessInfo.processInfo.environment
        let requested =
            env["ORNITH_TOOLS"] == "1" || env["TEST_RUNNER_ORNITH_TOOLS"] == "1"
        return requested
            && FileManager.default.fileExists(
                atPath: bundle("Ornith-1.0-9B-JANG_4M").appendingPathComponent("config.json").path)
    }

    /// A trimmed stand-in for what the app offers: a tool that is obviously
    /// irrelevant to general knowledge, and one that is obviously required for
    /// live data the model cannot know.
    /// Explicitly annotated at each level so the nested literals satisfy
    /// `[String: any Sendable]` without casts.
    static let tools: [[String: any Sendable]] = {
        let helpParams: [String: any Sendable] = [
            "type": "object",
            "properties": ["action": ["type": "string"] as [String: any Sendable]]
                as [String: any Sendable],
            "required": ["action"],
        ]
        let help: [String: any Sendable] = [
            "name": "osaurus_help",
            "description":
                "Bundled Osaurus user guide — answers questions about what Osaurus is and how its "
                + "features work (models, providers, agents, skills, plugins, MCP).",
            "parameters": helpParams,
        ]
        let timeParams: [String: any Sendable] = [
            "type": "object",
            "properties": [String: any Sendable](),
        ]
        let time: [String: any Sendable] = [
            "name": "get_current_time",
            "description": "Returns the current date and time.",
            "parameters": timeParams,
        ]
        return [
            ["type": "function", "function": help],
            ["type": "function", "function": time],
        ]
    }()

    struct Turn {
        let text: String
        let reasoning: String
        let calls: [String]
        let tokens: Int
        let progress: String
        var summary: String {
            let head = text.isEmpty
                ? "(no visible text)"
                : text.prefix(90).replacingOccurrences(of: "\n", with: " ")
            return "calls=\(calls.isEmpty ? "none" : calls.joined(separator: ",")) "
                + "tokens=\(tokens) reasoning=\(reasoning.count)ch "
                + "progress=\(progress.isEmpty ? "none" : "\"" + progress.prefix(120) + "\"") "
                + ":: \(head)"
        }
    }

    static func run(_ bundleName: String) async throws -> (noTool: Turn, needsTool: Turn) {
        let context = try await MLXLLM.LLMModelFactory.shared.load(
            from: bundle(bundleName), using: SwiftTransformersTokenizerLoader())

        func ask(_ prompt: String, system: String? = nil) async throws -> Turn {
            var messages: [[String: String]] = []
            if let system { messages.append(["role": "system", "content": system]) }
            messages.append(["role": "user", "content": prompt])
            let ids = try context.tokenizer.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: ["add_generation_prompt": true])
            // `Generation.chunk` is nil for `.toolCall`, so a correct tool call
            // shows up as empty text unless the tool channel is read too —
            // collecting only chunks scores a right answer as a miss.
            var text = ""
            var calls: [String] = []
            var tokenCount = 0
            var stopReason = "?"
            var reasoning = ""
            var progress = ""
            let stream = try MLXLMCommon.generate(
                input: LMInput(tokens: MLXArray(ids.map { Int32($0) })[.newAxis, .ellipsis]),
                parameters: GenerateParameters(maxTokens: 400, temperature: 0.0),
                context: context)
            for await item in stream {
                if let c = item.chunk { text += c }
                if let r = item.reasoning { reasoning += r }
                if let p = item.toolCallProgress { progress += p }
                if let call = item.toolCall { calls.append(call.function.name) }
                if let info = item.info {
                    tokenCount = info.generationTokenCount
                    stopReason = String(describing: info.stopReason)
                }
            }

            return Turn(text: text, reasoning: reasoning, calls: calls, tokens: tokenCount,
                        progress: progress)
        }

        // Answerable from the model's own knowledge — calling a tool is wrong.
        let a = try await ask(
            "Explain merge sort and compare it with quicksort on worst-case complexity, "
                + "memory use and cache behaviour.")
        // Not knowable without a tool — NOT calling one is wrong.
        let b = try await ask("What is the current date and time right now?")

        // The bare-template run has no system prompt, while the app always
        // composes one. If a plain assistant preamble is enough to make the
        // call appear, the failure is prompt composition rather than the model.
        let withSystem = try await ask(
            "What is the current date and time right now?",
            system: "You are a helpful assistant. Use the available tools when they are needed.")
        print("[tools]   live-data WITH system prompt: \(withSystem.summary)")

        return (a, b)
    }

    /// Scored from the emitted tool-call channel ONLY. Searching the prose is
    /// wrong: the model's own reasoning names the tool it is considering, so a
    /// substring check reports a call that never happened.

    @Test("4-bit vs 6-bit tool selection on the same prompts", .enabled(if: enabled))
    func quantAB() async throws {
        for name in ["Ornith-1.0-9B-JANG_4M", "Ornith-1.0-9B-JANG_6M"] {
            guard FileManager.default.fileExists(
                atPath: Self.bundle(name).appendingPathComponent("config.json").path)
            else {
                print("[tools] \(name): bundle missing, skipped")
                continue
            }
            let (noTool, needsTool) = try await Self.run(name)
            let spurious = !noTool.calls.isEmpty
            let missed = needsTool.calls.isEmpty
            let score = (spurious ? 0 : 1) + (missed ? 0 : 1)
            print("[tools] \(name): score \(score)/2  spurious-call-on-knowledge=\(spurious)  missed-call-on-live-data=\(missed)")
            print("[tools]   knowledge-question: \(noTool.summary)")
            print("[tools]   live-data:          \(needsTool.summary)")
            if !needsTool.reasoning.isEmpty {
                print("[tools]   live-data reasoning: \(needsTool.reasoning.prefix(180).replacingOccurrences(of: "\n", with: " "))")
            }
        }
    }
}
