//
//  TokenEstimator.swift
//  osaurus
//
//  Single canonical home for the `chars / 4` token-estimation heuristic
//  used across the chat pipeline (system prompts, conversation history,
//  tool-call envelopes, streamed deltas, attachments, response writers).
//
//  Before this type the same `max(1, text.count / 4)` literal lived in
//  ~14 sites — `ChatEngine`, `HTTPHandler`, `ChatView`, `ResponseWriters`,
//  `ToolRegistry`, `ContextBudgetManager`, `PromptSection`, etc. A change
//  to the constant in one place was invisible elsewhere, and the per-call
//  / per-message overhead constants drifted across sites (some used `+4`,
//  some used `+ 20`). Routing every site through `TokenEstimator` keeps
//  those constants in lock-step.
//
//  Naming convention:
//    - `estimate(_:)` — plain text → tokens.
//    - `toolCallTokens(...)` — assistant tool-call envelope (name + args
//      + id + envelope overhead).
//    - `messageOverheadTokens` — per-message role/delimiter overhead
//      added by `ContextBudgetManager.estimateTokens(for: [ChatMessage])`.
//
//  Calls that are NOT token estimation (Levenshtein distance thresholds,
//  base64-encoded byte math) are intentionally left untouched.
//

import Foundation

public enum TokenEstimator {

    /// The `chars per token` heuristic. Tuned for English-ish prompts;
    /// Asian-language prompts run ~2x denser, but the chat budget pipeline
    /// applies an 0.85 safety margin (`ContextBudgetManager.safetyMargin`)
    /// that absorbs that variance without per-language plumbing.
    public static let charsPerToken: Int = 4

    /// Per-message overhead added by `ContextBudgetManager.estimateTokens`
    /// when summing a `[ChatMessage]` array. Accounts for role tags,
    /// delimiters, and turn separators that the chat template injects
    /// around the user-visible content.
    public static let messageOverheadTokens: Int = 4

    /// Approximate byte cost of the JSON envelope wrapping each tool call
    /// (`{"id":"...","function":{...}}`). Folded into `toolCallTokens` so
    /// per-tool-call estimation stays consistent across diagnostic and
    /// budget paths.
    public static let toolCallEnvelopeChars: Int = 20

    /// Estimate tokens for a string. `nil` / empty inputs return 0; the
    /// `max(1, ...)` floor matches every legacy caller so long-tail
    /// 1-char strings don't silently round to zero tokens.
    public static func estimate(_ text: String?) -> Int {
        guard let text, !text.isEmpty else { return 0 }
        // `utf8.count`, not `count`: Character counting walks the whole
        // string grapheme by grapheme, and the budget pipeline re-estimates
        // entire conversations (every tool result included) inside view-body
        // evaluation — O(total transcript) per render was showing up as
        // main-thread hangs. The UTF-8 length is stored on native strings
        // (O(1)), identical for ASCII, and if anything a fairer proxy for
        // dense scripts, whose tokenizers see bytes-per-token closer to this.
        return max(1, text.utf8.count / charsPerToken)
    }

    /// Estimate tokens for a single tool-call envelope. `id` defaults to
    /// "" because some callers (streaming deltas) only have the function
    /// name + arguments and not the synthetic call id.
    public static func toolCallTokens(name: String, arguments: String, id: String = "") -> Int {
        // utf8.count for the same O(1) reason as `estimate`.
        max(
            1,
            (name.utf8.count + arguments.utf8.count + id.utf8.count + toolCallEnvelopeChars)
                / charsPerToken)
    }
}
