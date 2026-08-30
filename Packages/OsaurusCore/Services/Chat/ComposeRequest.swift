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
    /// Canonical local-bundle `config.json.model_type`, captured with the
    /// picker selection. Nil for remote/unresolved models, which deliberately
    /// fall back to identifier-based family routing.
    let modelType: String?
    let query: String
    let messages: [ChatMessage]
    let toolsDisabled: Bool
    let additionalToolNames: LoadedTools
    let frozenAlwaysLoadedNames: LoadedTools?
    /// Exact first-compose tool payloads. Names are still resolved through
    /// the live permission/feature gates; surviving baseline names reuse these
    /// canonical schemas so async registry metadata cannot rewrite a session's
    /// tokenizer prefix between turns.
    let frozenToolSpecs: [Tool]?
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
    /// Project of the session being composed for, when any. Folds the
    /// project's knowledge collections into the knowledge-tool gate and the
    /// prompt's grant descriptors.
    let projectId: UUID?

    init(
        agentId: UUID,
        executionMode: ExecutionMode,
        model: String? = nil,
        modelType: String? = nil,
        query: String = "",
        messages: [ChatMessage] = [],
        toolsDisabled: Bool = false,
        additionalToolNames: LoadedTools = [],
        frozenAlwaysLoadedNames: LoadedTools? = nil,
        frozenToolSpecs: [Tool]? = nil,
        frozenManifest: String? = nil,
        frozenSoul: String? = nil,
        trace: TTFTTrace? = nil,
        projectId: UUID? = nil
    ) {
        self.agentId = agentId
        self.executionMode = executionMode
        self.model = model
        self.modelType = modelType
        self.query = query
        self.messages = messages
        self.toolsDisabled = toolsDisabled
        self.additionalToolNames = additionalToolNames
        self.frozenAlwaysLoadedNames = frozenAlwaysLoadedNames
        self.frozenToolSpecs = frozenToolSpecs
        self.frozenManifest = frozenManifest
        self.frozenSoul = frozenSoul
        self.trace = trace
        self.projectId = projectId
    }
}
