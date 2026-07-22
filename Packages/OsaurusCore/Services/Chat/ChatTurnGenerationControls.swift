//
//  ChatTurnGenerationControls.swift
//  osaurus
//
//  Freezes prompt-affecting UI model controls for one logical chat turn.
//  Agent loops rebuild ChatCompletionRequest for every model step, so the
//  explicit Thinking choice must be copied to every reconstruction in both
//  its local runtime representation (`modelOptions`) and its wire-safe API
//  representation (`enable_thinking`).
//

import Foundation

struct ChatTurnGenerationControls: Sendable, Equatable {
    let modelOptions: [String: ModelOptionValue]?
    let enableThinking: Bool?

    static func capture(
        activeModelOptions: [String: ModelOptionValue]
    ) -> ChatTurnGenerationControls {
        let options = activeModelOptions.isEmpty ? nil : activeModelOptions

        // Only an explicit toggle becomes an API override. An absent value
        // remains nil so the bundle's chat-template default still owns fresh
        // models. `disableThinking` is the canonical stored option for every
        // current Thinking profile, including dynamically discovered local
        // profiles such as Ornith. Translate it directly instead of resolving
        // the model profile again on the send path; dynamic profile discovery
        // can touch the local model catalog and must not add synchronous TTFT.
        let enableThinking = options?["disableThinking"]?.boolValue.map { !$0 }

        return ChatTurnGenerationControls(
            modelOptions: options,
            enableThinking: enableThinking
        )
    }

    func apply(to request: inout ChatCompletionRequest) {
        request.modelOptions = modelOptions
        request.enable_thinking = enableThinking
    }
}
