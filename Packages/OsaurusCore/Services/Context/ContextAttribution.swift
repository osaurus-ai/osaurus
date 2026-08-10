//
//  ContextAttribution.swift
//  osaurus
//
//  Per-run context-cost attribution for the optimization harness: WHERE
//  the input tokens of an agent run come from, not just how many there
//  were. Composed once per eval run from the same `ComposedContext` the
//  loop actually sent (manifest sections, frozen tool schema, memory
//  snippet) plus end-of-run history composition, so the numbers are
//  deterministic (TokenEstimator-based), provider-independent, and add
//  up to the run's existing `promptTokensTotal` / `peakContextTokens`
//  telemetry rather than competing with it.
//

import Foundation

/// Decode-friendly breakdown of one run's context cost by contributor.
public struct ContextAttribution: Sendable, Codable, Equatable {

    /// One system-prompt section's cost (mirrors `PromptSection`).
    public struct SectionCost: Sendable, Codable, Equatable {
        public let id: String
        public let label: String
        public let tokens: Int
        /// "static" (KV-cache-reusable prefix) or "dynamic".
        public let cacheability: String

        public init(id: String, label: String, tokens: Int, cacheability: String) {
            self.id = id
            self.label = label
            self.tokens = tokens
            self.cacheability = cacheability
        }
    }

    /// One tool schema's cost in the outbound request.
    public struct ToolCost: Sendable, Codable, Equatable {
        public let name: String
        public let tokens: Int

        public init(name: String, tokens: Int) {
            self.name = name
            self.tokens = tokens
        }
    }

    /// End-of-run conversation-history composition (everything that is
    /// neither the system prompt nor the tool schema on the last step).
    public struct HistoryCost: Sendable, Codable, Equatable {
        public let userTokens: Int
        public let assistantTokens: Int
        public let toolResultTokens: Int
        public let toolResultCount: Int

        public init(
            userTokens: Int,
            assistantTokens: Int,
            toolResultTokens: Int,
            toolResultCount: Int
        ) {
            self.userTokens = userTokens
            self.assistantTokens = assistantTokens
            self.toolResultTokens = toolResultTokens
            self.toolResultCount = toolResultCount
        }
    }

    /// Every system-prompt section that survived composition, in render
    /// order, with its estimated token cost.
    public let sections: [SectionCost]
    /// Every tool schema sent on the request, with per-tool cost.
    public let tools: [ToolCost]
    /// Sum of `sections` — the system prompt's estimated cost.
    public let systemPromptTokens: Int
    /// Sum of `tools` — the frozen schema's estimated cost.
    public let toolSchemaTokens: Int
    /// Static-prefix portion of the system prompt (KV-reusable window).
    public let staticPrefixTokens: Int
    /// Estimated cost of the per-turn memory snippet the compose resolved
    /// (nil when memory was disabled/empty). Reported even when the run
    /// path did not inject it, so ablations can price the memory axis.
    public let memoryTokens: Int?
    /// First model step's input estimate — the cold-prefill cost and the
    /// number the first-step optimization axis drives down.
    public let firstStepInputTokens: Int?
    /// Largest single-step input estimate (context high-water mark).
    public let peakStepInputTokens: Int?
    /// Input estimate summed across every model step.
    public let cumulativeInputTokens: Int?
    /// Number of model steps that contributed to the cumulative total.
    public let modelSteps: Int?
    /// End-of-run history composition; nil when the run made no model call.
    public let history: HistoryCost?
    /// Static prefix + canonical tool payload hash (`ComposedContext.cacheHint`)
    /// — the byte-stability evidence for KV-prefix comparisons across runs.
    public let staticPrefixHash: String?

    public init(
        sections: [SectionCost],
        tools: [ToolCost],
        systemPromptTokens: Int,
        toolSchemaTokens: Int,
        staticPrefixTokens: Int,
        memoryTokens: Int? = nil,
        firstStepInputTokens: Int? = nil,
        peakStepInputTokens: Int? = nil,
        cumulativeInputTokens: Int? = nil,
        modelSteps: Int? = nil,
        history: HistoryCost? = nil,
        staticPrefixHash: String? = nil
    ) {
        self.sections = sections
        self.tools = tools
        self.systemPromptTokens = systemPromptTokens
        self.toolSchemaTokens = toolSchemaTokens
        self.staticPrefixTokens = staticPrefixTokens
        self.memoryTokens = memoryTokens
        self.firstStepInputTokens = firstStepInputTokens
        self.peakStepInputTokens = peakStepInputTokens
        self.cumulativeInputTokens = cumulativeInputTokens
        self.modelSteps = modelSteps
        self.history = history
        self.staticPrefixHash = staticPrefixHash
    }

    /// Top-N contributors across sections AND tools, largest first —
    /// the "where is the context going" headline for reports.
    public func topContributors(_ n: Int = 3) -> [(name: String, tokens: Int)] {
        let all =
            sections.map { (name: "§\($0.id)", tokens: $0.tokens) }
            + tools.map { (name: "tool:\($0.name)", tokens: $0.tokens) }
        return Array(all.sorted { $0.tokens > $1.tokens }.prefix(n))
    }

    // MARK: - Builders

    /// Build the composition-side attribution from a manifest + tool set
    /// (the exact artifacts a compose produced). Pure and deterministic.
    static func build(
        manifest: PromptManifest,
        tools: [Tool],
        memorySection: String?,
        staticPrefixHash: String?,
        firstStepInputTokens: Int? = nil,
        peakStepInputTokens: Int? = nil,
        cumulativeInputTokens: Int? = nil,
        modelSteps: Int? = nil,
        history: [ChatMessage]? = nil
    ) -> ContextAttribution {
        let sectionCosts = manifest.sections.compactMap { section -> SectionCost? in
            let tokens = section.estimatedTokens
            guard tokens > 0 else { return nil }
            return SectionCost(
                id: section.id,
                label: section.label,
                tokens: tokens,
                cacheability: section.cacheability.rawValue
            )
        }
        let toolCosts = tools.map { tool in
            ToolCost(
                name: tool.function.name,
                tokens: ToolSpecTokenEstimator.estimate(
                    name: tool.function.name,
                    description: tool.function.description,
                    parameters: tool.function.parameters
                )
            )
        }
        let memoryTokens = memorySection.map { TokenEstimator.estimate($0) }
        return ContextAttribution(
            sections: sectionCosts,
            tools: toolCosts,
            systemPromptTokens: sectionCosts.reduce(0) { $0 + $1.tokens },
            toolSchemaTokens: toolCosts.reduce(0) { $0 + $1.tokens },
            staticPrefixTokens: manifest.staticPrefixTokens,
            memoryTokens: (memoryTokens ?? 0) > 0 ? memoryTokens : nil,
            firstStepInputTokens: firstStepInputTokens,
            peakStepInputTokens: peakStepInputTokens,
            cumulativeInputTokens: cumulativeInputTokens,
            modelSteps: modelSteps,
            history: history.map { historyCost($0) },
            staticPrefixHash: staticPrefixHash
        )
    }

    /// Fold a message array into per-role token sums. System messages are
    /// excluded — the system prompt is already attributed section-by-section.
    static func historyCost(_ messages: [ChatMessage]) -> HistoryCost {
        var user = 0
        var assistant = 0
        var toolResults = 0
        var toolResultCount = 0
        for message in messages {
            switch message.role {
            case "user":
                user += TokenEstimator.estimate(message.content)
            case "assistant":
                assistant += TokenEstimator.estimate(message.content)
                assistant += TokenEstimator.estimate(message.reasoning_content)
                for call in message.tool_calls ?? [] {
                    assistant += TokenEstimator.estimate(call.function.name)
                    assistant += TokenEstimator.estimate(call.function.arguments)
                }
            case "tool":
                toolResults += TokenEstimator.estimate(message.content)
                toolResultCount += 1
            default:
                break
            }
        }
        return HistoryCost(
            userTokens: user,
            assistantTokens: assistant,
            toolResultTokens: toolResults,
            toolResultCount: toolResultCount
        )
    }
}
