//
//  AnarlogAnswerReserveLiveTests.swift
//  osaurus
//
//  Real-model A/B for the Anarlog "AI generation did not return any text"
//  class: an OpenAI-compatible client with a finite max_tokens gets an empty
//  `content` whenever the think block spends the whole cap. The armed
//  reasoning budget must force `</think>` with answer room left; the
//  unbudgeted control demonstrates the failure the fix rescues.
//
//  Local-only (loads a real bundle): ANARLOG_LIVE=1 plus the JANG_2D quant
//  under ~/models. CI skips cleanly.
//

import Foundation
import MLXLMCommon
import MLXVLM
import Testing

@testable import OsaurusCore

struct AnarlogAnswerReserveLiveTests {

    static let bundle = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("models/JANGQ-AI/Qwen3.8-27B-JANG_2D")

    static var enabled: Bool {
        ProcessInfo.processInfo.environment["ANARLOG_LIVE"] == "1"
            && FileManager.default.fileExists(
                atPath: bundle.appendingPathComponent("config.json").path)
    }

    /// Meaty enough that default-effort (xhigh) thinking reliably outruns a
    /// 300-token cap on its own.
    static let transcript = """
        Summarize this meeting transcript in two sentences. Transcript: \
        Ana opened with the Q3 revenue numbers, which came in eight percent \
        under plan because two enterprise renewals slipped to October. Marco \
        walked through the migration timeline and flagged that the auth \
        service rewrite is blocking the EU rollout. Priya reported that \
        support ticket volume doubled after the pricing change and proposed \
        a dedicated triage rotation. The group agreed to move the launch \
        review to Thursday, ask legal to fast-track the DPA template, and \
        have Marco present a de-scoped rollout plan. Ana closed by asking \
        everyone to update their OKR status before Friday.
        """

    private func run(budget: Int?) async throws -> (content: String, reasoning: String) {
        let context = try await MLXVLM.VLMModelFactory.shared.load(
            from: Self.bundle, using: SwiftTransformersTokenizerLoader())
        let input = try await context.processor.prepare(
            input: UserInput(prompt: Self.transcript))
        var parameters = GenerateParameters(maxTokens: 300, temperature: 0.0)
        parameters.requestedReasoningBudgetTokens = budget
        let engine = BatchEngine(context: context)
        var content = ""
        var reasoning = ""
        let stream = await engine.generate(input: input, parameters: parameters)
        for await item in stream {
            switch item {
            case .chunk(let c): content += c
            case .reasoning(let r): reasoning += r
            default: break
            }
        }
        return (content, reasoning)
    }

    @Test(
        "the armed reserve forces a think close with answer room; the control dies inside the block",
        .enabled(if: enabled))
    func armedBudgetRescuesTheAnswer() async throws {
        // Exactly what the adapter would arm for an httpAPI request at this cap.
        let budget = try #require(
            MLXBatchAdapter.apiReasoningAnswerBudget(requestSource: .httpAPI, maxTokens: 300))

        let rescued = try await run(budget: budget)
        print("[anarlog-live] budgeted: reasoning=\(rescued.reasoning.count)ch content=\(rescued.content.count)ch")
        print("[anarlog-live] budgeted content: \(rescued.content)")
        // The client-visible contract: `content` is non-empty. The engine
        // peels reasoning into its own events, so this is exactly what a
        // non-streaming chat completion would return as message.content.
        #expect(
            !rescued.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the ceiling did not rescue a visible answer (reasoning ran \(rescued.reasoning.count)ch)"
        )

        let control = try await run(budget: nil)
        print(
            "[anarlog-live] control: reasoning=\(control.reasoning.count)ch content=\(control.content.count)ch"
        )
        // The control documents the failure being fixed. Not a hard assert —
        // a model COULD occasionally answer within the cap — but record it.
        if !control.content.isEmpty {
            print("[anarlog-live] note: control produced content on its own this run")
        }
    }
}
