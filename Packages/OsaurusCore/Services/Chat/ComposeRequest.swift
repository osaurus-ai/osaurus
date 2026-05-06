//
//  ComposeRequest.swift
//  osaurus
//
//  Parameter bundle for `SystemPromptComposer.composeChatContext`.
//
//  Replaces the 11-positional-param signature so call sites read field
//  names instead of an unlabeled tail of optionals, and so future
//  additions (e.g. a request-scoped budget override) don't have to be
//  threaded through every wrapper that calls the composer. The optional
//  `TTFTTrace` was the worst offender — it threaded down every level
//  as a separate parameter.
//

import Foundation

struct ComposeRequest: Sendable {
    let agentId: UUID
    let executionMode: ExecutionMode
    let model: String?
    let query: String
    let messages: [ChatMessage]
    let toolsDisabled: Bool
    let cachedPreflight: PreflightResult?
    let additionalToolNames: LoadedTools
    let frozenAlwaysLoadedNames: LoadedTools?
    let trace: TTFTTrace?

    init(
        agentId: UUID,
        executionMode: ExecutionMode,
        model: String? = nil,
        query: String = "",
        messages: [ChatMessage] = [],
        toolsDisabled: Bool = false,
        cachedPreflight: PreflightResult? = nil,
        additionalToolNames: LoadedTools = [],
        frozenAlwaysLoadedNames: LoadedTools? = nil,
        trace: TTFTTrace? = nil
    ) {
        self.agentId = agentId
        self.executionMode = executionMode
        self.model = model
        self.query = query
        self.messages = messages
        self.toolsDisabled = toolsDisabled
        self.cachedPreflight = cachedPreflight
        self.additionalToolNames = additionalToolNames
        self.frozenAlwaysLoadedNames = frozenAlwaysLoadedNames
        self.trace = trace
    }
}
