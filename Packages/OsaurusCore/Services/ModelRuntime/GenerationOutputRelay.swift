//
//  GenerationOutputRelay.swift
//  osaurus
//
//  "The last letters hang": after the final token, vmlx runs its post-generation
//  cache store (measured 9.5–15 s on a 96 GB bundle, 2026-09-04) and only then
//  closes the stream. MLXBatchAdapter deliberately withholds the terminal `.info`
//  until that drain so an immediate follow-up request cannot enter ModelRuntime
//  before this one's allocator window closes. That ordering stays. What the UI
//  needs is a separate, earlier fact — "the model's OUTPUT is complete" — so the
//  streaming cursor can stop at the last letter and the turn can stamp its
//  completion, while the send gate keeps waiting for the real end of the run.
//
//  The adapter announces output completion here the moment `.info` arrives;
//  the chat view subscribes for the duration of its run.
//

import Combine
import Foundation

/// Not actor-isolated: the announcer runs on the adapter's producer task; the
/// published value is only ever written on the main queue, and the chat view
/// already receives on the main run loop.
final class GenerationOutputRelay: ObservableObject, @unchecked Sendable {
    static let shared = GenerationOutputRelay()

    struct Completion: Equatable {
        let modelName: String
        let at: Date
        /// Decode tokens vmlx counted for the run, when the info carried them.
        let generationTokens: Int?
    }

    @Published private(set) var lastCompletion: Completion?

    func announce(modelName: String, generationTokens: Int?) {
        let completion = Completion(
            modelName: modelName, at: Date(), generationTokens: generationTokens)
        DispatchQueue.main.async { self.lastCompletion = completion }
    }
}
