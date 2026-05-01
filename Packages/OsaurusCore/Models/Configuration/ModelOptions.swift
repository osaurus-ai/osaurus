//
//  ModelOptions.swift
//  osaurus
//
//  Registry-based model options system. Each ModelProfile declares the options
//  a family of models supports; the UI renders them dynamically and the values
//  flow through to the request builder.
//

import Foundation

// MARK: - Option Value

enum ModelOptionValue: Sendable, Equatable, Hashable, Codable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)

    var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
}

// MARK: - Option Definition

struct ModelOptionSegment: Identifiable, Sendable {
    let id: String
    let label: String
}

struct ModelOptionDefinition: Identifiable, Sendable {
    enum Kind: Sendable {
        case segmented([ModelOptionSegment])
        case toggle(default: Bool)
    }

    let id: String
    let label: String
    let icon: String?
    let kind: Kind

    init(id: String, label: String, icon: String? = nil, kind: Kind) {
        self.id = id
        self.label = label
        self.icon = icon
        self.kind = kind
    }
}

// MARK: - Model Profile Protocol

protocol ModelProfile: Sendable {
    static func matches(modelId: String) -> Bool
    static var displayName: String { get }
    static var options: [ModelOptionDefinition] { get }
    static var defaults: [String: ModelOptionValue] { get }

    /// Mapping for a dedicated "Thinking/Reasoning" toggle in the input area.
    /// Returns the option ID (like "disableThinking") and whether true means "Enabled".
    static var thinkingOption: (id: String, inverted: Bool)? { get }
}

extension ModelProfile {
    static var thinkingOption: (id: String, inverted: Bool)? { nil }
}

// MARK: - Registry

enum ModelProfileRegistry {
    static let profiles: [any ModelProfile.Type] = [
        VeniceModelProfile.self,
        OpenAIReasoningProfile.self,
        QwenThinkingProfile.self,
        NemotronThinkingProfile.self,
        LagunaThinkingProfile.self,
        Gemini31FlashImageProfile.self,
        GeminiProImageProfile.self,
        GeminiFlashImageProfile.self,
        AutoThinkingProfile.self,
    ]

    static func profile(for modelId: String) -> (any ModelProfile.Type)? {
        profiles.first { $0.matches(modelId: modelId) }
    }

    static func defaults(for modelId: String) -> [String: ModelOptionValue] {
        profile(for: modelId)?.defaults ?? [:]
    }

    static func options(for modelId: String) -> [ModelOptionDefinition] {
        profile(for: modelId)?.options ?? []
    }
}

// MARK: - OpenAI Reasoning Profile

/// OpenAI reasoning models (o-series, gpt-5+) — supports reasoning effort control.
struct OpenAIReasoningProfile: ModelProfile {
    static let displayName = "Reasoning"

    private static let reasoningModelPrefixes = ["o1", "o3", "o4", "gpt-5"]

    static func matches(modelId: String) -> Bool {
        let bare =
            modelId.lowercased().split(separator: "/").last.map(String.init)
            ?? modelId.lowercased()
        return reasoningModelPrefixes.contains { bare.hasPrefix($0) }
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "reasoningEffort",
            label: "Reasoning Effort",
            icon: "brain",
            kind: .segmented([
                ModelOptionSegment(id: "minimal", label: "Minimal"),
                ModelOptionSegment(id: "low", label: "Low"),
                ModelOptionSegment(id: "medium", label: "Medium"),
                ModelOptionSegment(id: "high", label: "High"),
            ])
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "reasoningEffort": .string("medium")
    ]
}

// MARK: - Qwen Thinking Profile

/// Qwen3 / Qwen3.5 local models — supports disabling thinking via `enable_thinking` chat template kwarg.
/// Excludes Qwen3-Coder variants which are non-thinking only.
struct QwenThinkingProfile: ModelProfile {
    static let displayName = "Qwen Thinking"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.contains("qwen3") && !lower.contains("coder")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "disableThinking",
            label: "Disable Thinking",
            icon: "brain.head.profile",
            kind: .toggle(default: true)
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "disableThinking": .bool(true)
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}

// MARK: - Nemotron-3 Thinking Profile

/// Nemotron-3-Nano-Omni Reasoning models — `model_type=nemotron_h` hybrid
/// Mamba+Attn+MoE bundles whose chat template reads an `enable_thinking`
/// kwarg. Defaults `disableThinking: true` for the same reason
/// `QwenThinkingProfile` does: per
/// `jang/research/NEMOTRON-OMNI-RUNTIME-2026-04-28.md` §9, the SKU is
/// "Reasoning V3" and its training extends `<think>` blocks through
/// arbitrary self-verification on validation-style prompts (the same
/// pattern that surfaced as trapped-thinking on Qwen3.6-A3B). Forcing
/// thinking off for chat workloads is the recommended operating point;
/// users who want CoT can toggle the chip on per turn.
///
/// Match excludes `coder` variants (none ship today, but mirroring
/// `QwenThinkingProfile`'s shape for consistency if NVIDIA publishes one).
struct NemotronThinkingProfile: ModelProfile {
    static let displayName = "Nemotron Thinking"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.contains("nemotron-3") && !lower.contains("coder")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "disableThinking",
            label: "Disable Thinking",
            icon: "brain.head.profile",
            kind: .toggle(default: true)
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "disableThinking": .bool(true)
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}

// MARK: - Laguna Thinking Profile

/// Poolside Laguna (`model_type=laguna`) — agentic-coding 33B/3B-active MoE
/// whose chat template (`laguna_glm_thinking_v5/chat_template.jinja`)
/// reads an `enable_thinking` Jinja kwarg. The shipped template defaults
/// `enable_thinking=false`, which means by default Laguna emits no
/// thinking block — straight-to-answer behavior optimal for coding /
/// agentic flows. The profile mirrors that: `disableThinking: true` by
/// default, so the in-template default is preserved unless the user
/// explicitly toggles thinking on (CoT for hard reasoning steps).
///
/// Match is `laguna` substring lower-cased; covers any future Laguna
/// variant (e.g. Laguna-S, Laguna-M) without a registry edit. There is
/// no `coder` exclusion because Laguna IS the coder family — exclusion
/// would be a no-op.
struct LagunaThinkingProfile: ModelProfile {
    static let displayName = "Laguna Thinking"

    static func matches(modelId: String) -> Bool {
        return modelId.lowercased().contains("laguna")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "disableThinking",
            label: "Disable Thinking",
            icon: "brain.head.profile",
            kind: .toggle(default: true)
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "disableThinking": .bool(true)
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}

// MARK: - Auto Thinking Profile (chat-template driven)

/// Fallback profile that activates for locally-installed models whose chat
/// template exposes an `enable_thinking` kwarg and uses thinking markers the
/// runtime can process. Registered last so that explicit family profiles
/// (Qwen, Venice, etc.) still win when they match.
struct AutoThinkingProfile: ModelProfile {
    static let displayName = "Thinking"

    static func matches(modelId: String) -> Bool {
        LocalReasoningCapability.capability(forModelId: modelId).isToggleableThinking
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "disableThinking",
            label: "Disable Thinking",
            icon: "brain.head.profile",
            kind: .toggle(default: false)
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "disableThinking": .bool(false)
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}

// MARK: - Shared Segments

private let geminiAspectRatioSegments: [ModelOptionSegment] = [
    ModelOptionSegment(id: "auto", label: "Auto"),
    ModelOptionSegment(id: "1:1", label: "1:1"),
    ModelOptionSegment(id: "2:3", label: "2:3"),
    ModelOptionSegment(id: "3:2", label: "3:2"),
    ModelOptionSegment(id: "3:4", label: "3:4"),
    ModelOptionSegment(id: "4:3", label: "4:3"),
    ModelOptionSegment(id: "4:5", label: "4:5"),
    ModelOptionSegment(id: "5:4", label: "5:4"),
    ModelOptionSegment(id: "9:16", label: "9:16"),
    ModelOptionSegment(id: "16:9", label: "16:9"),
    ModelOptionSegment(id: "21:9", label: "21:9"),
]

private let geminiExtendedAspectRatioSegments: [ModelOptionSegment] = [
    ModelOptionSegment(id: "auto", label: "Auto"),
    ModelOptionSegment(id: "1:1", label: "1:1"),
    ModelOptionSegment(id: "1:4", label: "1:4"),
    ModelOptionSegment(id: "1:8", label: "1:8"),
    ModelOptionSegment(id: "2:3", label: "2:3"),
    ModelOptionSegment(id: "3:2", label: "3:2"),
    ModelOptionSegment(id: "3:4", label: "3:4"),
    ModelOptionSegment(id: "4:1", label: "4:1"),
    ModelOptionSegment(id: "4:3", label: "4:3"),
    ModelOptionSegment(id: "4:5", label: "4:5"),
    ModelOptionSegment(id: "5:4", label: "5:4"),
    ModelOptionSegment(id: "8:1", label: "8:1"),
    ModelOptionSegment(id: "9:16", label: "9:16"),
    ModelOptionSegment(id: "16:9", label: "16:9"),
    ModelOptionSegment(id: "21:9", label: "21:9"),
]

private let geminiOutputTypeSegments: [ModelOptionSegment] = [
    ModelOptionSegment(id: "textAndImage", label: "Text & Image"),
    ModelOptionSegment(id: "imageOnly", label: "Image Only"),
]

// MARK: - Gemini 3.1 Flash Image Profile (Nano Banana 2)

/// Gemini 3.1 Flash Image Preview — supports extended aspect ratios, resolution (512px/1K/2K/4K), and output type.
struct Gemini31FlashImageProfile: ModelProfile {
    static let displayName = "Image Generation (3.1 Flash)"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.contains("gemini-3.1") && lower.contains("flash") && lower.contains("image")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "aspectRatio",
            label: "Aspect Ratio",
            icon: "aspectratio",
            kind: .segmented(geminiExtendedAspectRatioSegments)
        ),
        ModelOptionDefinition(
            id: "imageSize",
            label: "Resolution",
            icon: "arrow.up.right.and.arrow.down.left",
            kind: .segmented([
                ModelOptionSegment(id: "auto", label: "Auto"),
                ModelOptionSegment(id: "512px", label: "0.5K"),
                ModelOptionSegment(id: "1K", label: "1K"),
                ModelOptionSegment(id: "2K", label: "2K"),
                ModelOptionSegment(id: "4K", label: "4K"),
            ])
        ),
        ModelOptionDefinition(
            id: "outputType",
            label: "Output",
            icon: "photo.on.rectangle",
            kind: .segmented(geminiOutputTypeSegments)
        ),
    ]

    static let defaults: [String: ModelOptionValue] = [
        "aspectRatio": .string("auto"),
        "imageSize": .string("auto"),
        "outputType": .string("textAndImage"),
    ]
}

// MARK: - Gemini 3 Pro Image Profile (Nano Banana Pro)

/// Gemini 3 Pro Image Preview — supports aspect ratio, resolution (1K/2K/4K), and output type.
struct GeminiProImageProfile: ModelProfile {
    static let displayName = "Image Generation (Pro)"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.contains("nano-banana")
            || (lower.contains("gemini-3") && lower.contains("pro") && lower.contains("image"))
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "aspectRatio",
            label: "Aspect Ratio",
            icon: "aspectratio",
            kind: .segmented(geminiAspectRatioSegments)
        ),
        ModelOptionDefinition(
            id: "imageSize",
            label: "Resolution",
            icon: "arrow.up.right.and.arrow.down.left",
            kind: .segmented([
                ModelOptionSegment(id: "auto", label: "Auto"),
                ModelOptionSegment(id: "1K", label: "1K"),
                ModelOptionSegment(id: "2K", label: "2K"),
                ModelOptionSegment(id: "4K", label: "4K"),
            ])
        ),
        ModelOptionDefinition(
            id: "outputType",
            label: "Output",
            icon: "photo.on.rectangle",
            kind: .segmented(geminiOutputTypeSegments)
        ),
    ]

    static let defaults: [String: ModelOptionValue] = [
        "aspectRatio": .string("auto"),
        "imageSize": .string("auto"),
        "outputType": .string("textAndImage"),
    ]
}

// MARK: - Gemini Flash Image Profile (Nano Banana)

/// Gemini 2.5 Flash Image — supports aspect ratio and output type (no resolution control).
struct GeminiFlashImageProfile: ModelProfile {
    static let displayName = "Image Generation"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.contains("flash") && lower.contains("image") && !lower.contains("gemini-3")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "aspectRatio",
            label: "Aspect Ratio",
            icon: "aspectratio",
            kind: .segmented(geminiAspectRatioSegments)
        ),
        ModelOptionDefinition(
            id: "outputType",
            label: "Output",
            icon: "photo.on.rectangle",
            kind: .segmented(geminiOutputTypeSegments)
        ),
    ]

    static let defaults: [String: ModelOptionValue] = [
        "aspectRatio": .string("auto"),
        "outputType": .string("textAndImage"),
    ]
}

// MARK: - Venice AI Model Profile

/// Venice AI models — supports web search, thinking control, and Venice system prompt toggle.
/// See https://docs.venice.ai/api-reference/api-spec for venice_parameters details.
struct VeniceModelProfile: ModelProfile {
    static let displayName = "Venice AI"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.hasPrefix("venice-ai/")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "enableWebSearch",
            label: "Web Search",
            icon: "magnifyingglass",
            kind: .segmented([
                ModelOptionSegment(id: "off", label: "Off"),
                ModelOptionSegment(id: "on", label: "On"),
                ModelOptionSegment(id: "auto", label: "Auto"),
            ])
        ),
        ModelOptionDefinition(
            id: "disableThinking",
            label: "Disable Thinking",
            icon: "brain.head.profile",
            kind: .toggle(default: true)
        ),
        ModelOptionDefinition(
            id: "includeVeniceSystemPrompt",
            label: "Venice System Prompt",
            icon: "text.bubble",
            kind: .toggle(default: true)
        ),
    ]

    static let defaults: [String: ModelOptionValue] = [
        "enableWebSearch": .string("off"),
        "disableThinking": .bool(true),
        "includeVeniceSystemPrompt": .bool(true),
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}
