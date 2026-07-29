//
//  FireworksAPI.swift
//  osaurus
//
//  Fireworks AI gateway catalog response models. Fireworks' OpenAI-compatible
//  `/inference/v1/models` endpoint only lists the account's deployed/default
//  serverless models, so full model discovery pages through the gateway
//  endpoint `GET https://api.fireworks.ai/v1/accounts/fireworks/models`.
//

import Foundation

/// One page of the Fireworks gateway `ListModels` response.
struct FireworksModelsPage: Decodable, Sendable {
    let models: [FireworksModel]?
    let nextPageToken: String?
}

/// A model entry from the Fireworks gateway catalog.
struct FireworksModel: Decodable, Sendable {
    /// Full resource name, e.g. `accounts/fireworks/models/llama-v3p1-70b-instruct`.
    /// The OpenAI-compatible inference endpoints accept this as the model id.
    let name: String
    let state: String?
    let kind: String?
    let supportsServerless: Bool?
    let conversationConfig: FireworksConversationConfig?

    /// Serverless-hosted, chat-capable, live model — what the model picker
    /// should show. `conversationConfig` presence is Fireworks' signal that
    /// the Chat Completions API is enabled for the model, but embedding and
    /// reranker models carry one too (verified live), so `kind` is also
    /// checked. Unknown/missing kinds are kept to stay forward-compatible.
    var isServerlessChatModel: Bool {
        state == "READY"
            && supportsServerless == true
            && conversationConfig != nil
            && !(kind?.contains("EMBEDDING") ?? false)
    }
}

/// `conversationConfig` is only checked for presence; its fields are unused.
struct FireworksConversationConfig: Decodable, Sendable {}
