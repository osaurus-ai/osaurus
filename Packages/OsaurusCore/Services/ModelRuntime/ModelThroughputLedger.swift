//
//  ModelThroughputLedger.swift
//  osaurus
//
//  The last decode rate seen for each model, for budgets that have to scale
//  with the model rather than assume one speed (the Architect's draft
//  phase). Fed by every generation step that reports a rate and by hidden
//  agent runs; nothing is persisted.
//

import Foundation
import os

enum ModelThroughputLedger {
    /// Steps shorter than this decode too few tokens for a rate worth
    /// keeping (a bare tool call, a one-word reply).
    static let minimumTokens = 32

    private struct State {
        var rates: [String: Double] = [:]
        var latest: String?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func record(model: String, tokensPerSecond: Double, tokens: Int? = nil) {
        guard tokensPerSecond.isFinite, tokensPerSecond > 0 else { return }
        if let tokens, tokens < minimumTokens { return }
        let key = key(model)
        guard !key.isEmpty else { return }
        state.withLock {
            $0.rates[key] = tokensPerSecond
            $0.latest = key
        }
    }

    /// The last rate for `model`; with no model, the last rate for whichever
    /// model decoded most recently (the resident one).
    static func tokensPerSecond(for model: String?) -> Double? {
        state.withLock { state in
            guard let model else { return state.latest.flatMap { state.rates[$0] } }
            return state.rates[key(model)]
        }
    }

    static func reset() {
        state.withLock { $0 = State() }
    }

    /// Bundle ids and picker names for one model differ in case and in the
    /// publisher prefix (`mlx-community/Qwen3-4B-4bit` vs `qwen3-4b-4bit`).
    private static func key(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }
}
