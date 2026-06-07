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
    let additionalToolNames: LoadedTools
    let frozenAlwaysLoadedNames: LoadedTools?
    /// Turn-1 rendered enabled-capabilities manifest echoed back on turn 2+
    /// so the static system-prompt prefix stays byte-identical across the
    /// session (mirrors `frozenAlwaysLoadedNames`). `nil` = render fresh;
    /// non-nil = reuse verbatim.
    let frozenManifest: String?
    /// Turn-1 rendered SOUL.md content echoed back on turn 2+ so a mid-session
    /// `SOUL.md` edit doesn't rewrite the static prefix (mirrors
    /// `frozenManifest`). `nil` = read fresh; non-nil = reuse verbatim.
    let frozenSoul: String?
    let trace: TTFTTrace?

    init(
        agentId: UUID,
        executionMode: ExecutionMode,
        model: String? = nil,
        query: String = "",
        messages: [ChatMessage] = [],
        toolsDisabled: Bool = false,
        additionalToolNames: LoadedTools = [],
        frozenAlwaysLoadedNames: LoadedTools? = nil,
        frozenManifest: String? = nil,
        frozenSoul: String? = nil,
        trace: TTFTTrace? = nil
    ) {
        self.agentId = agentId
        self.executionMode = executionMode
        self.model = model
        self.query = query
        self.messages = messages
        self.toolsDisabled = toolsDisabled
        self.additionalToolNames = additionalToolNames
        self.frozenAlwaysLoadedNames = frozenAlwaysLoadedNames
        self.frozenManifest = frozenManifest
        self.frozenSoul = frozenSoul
        self.trace = trace
    }
}
