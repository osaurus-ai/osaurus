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
    /// Returns the option ID (like "disableThinking") and whether the stored
    /// boolean is inverted (`true` means disabled, so the UI shows OFF).
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
        MistralReasoningProfile.self,
        QwenThinkingProfile.self,
        NemotronThinkingProfile.self,
        LagunaThinkingProfile.self,
        DSV4ReasoningProfile.self,
        Hy3ReasoningProfile.self,
        LingRuntimeProfile.self,
        ZayaThinkingProfile.self,
        Gemma4RuntimeProfile.self,
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

    static func normalizedOptions(
        for modelId: String,
        persisted: [String: ModelOptionValue]?
    ) -> [String: ModelOptionValue] {
        let definitions = options(for: modelId)
        guard !definitions.isEmpty else { return [:] }

        // Do not synthesize profile defaults into requests. Missing values mean
        // "let the model bundle/runtime decide"; only explicit UI/API choices
        // are allowed to reach modelOptions.
        guard let persisted else { return [:] }

        let allowedIds = Set(definitions.map(\.id))
        // Segment ids allowed per option. A persisted segment value that is no
        // longer offered (e.g. an old Mistral `reasoningEffort: "medium"` after
        // the option set was narrowed to none/high) must be dropped, not sent to
        // the wire, where it would be rejected.
        let allowedSegmentValues: [String: Set<String>] = definitions.reduce(into: [:]) { acc, def in
            if case .segmented(let segments) = def.kind {
                acc[def.id] = Set(segments.map(\.id))
            }
        }
        return persisted.filter { key, value in
            guard allowedIds.contains(key) else { return false }
            guard let segments = allowedSegmentValues[key] else { return true }
            guard let stringValue = value.stringValue else { return true }
            return segments.contains(stringValue)
        }
    }

    static func boolOptionValue(
        for modelId: String,
        optionId: String,
        values: [String: ModelOptionValue]
    ) -> Bool? {
        values[optionId]?.boolValue
    }

    static func thinkingEnabled(
        for modelId: String,
        values: [String: ModelOptionValue]
    ) -> Bool? {
        guard let option = profile(for: modelId)?.thinkingOption,
            let value = boolOptionValue(for: modelId, optionId: option.id, values: values)
        else {
            return nil
        }
        return option.inverted ? !value : value
    }
}

// MARK: - DSV4 Reasoning Profile

/// DeepSeek-V4 / DSV4 Flash JANG bundles use vmlx's dedicated DSV4 encoder
/// rather than a generic `enable_thinking`-only Jinja path. The runtime has
/// three intentional modes:
/// - instruct: closed `</think>` assistant tail, answer on content rail
/// - reasoning: open `<think>` assistant tail, normal reasoning split
/// - max: raw DSV4 max reasoning effort; Osaurus passes it through to vmlx
///   unchanged so runtime issues are fixed at the engine layer, not hidden here
struct DSV4ReasoningProfile: ModelProfile {
    static let displayName = "DSV4 Reasoning"

    static func matches(modelId: String) -> Bool {
        ModelFamilyNames.isDSV4Family(modelId)
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "reasoningEffort",
            label: L("Reasoning Mode"),
            icon: "brain.head.profile",
            kind: .segmented([
                ModelOptionSegment(id: "instruct", label: L("Instruct")),
                ModelOptionSegment(id: "high", label: L("Reasoning")),
                ModelOptionSegment(id: "max", label: L("Max")),
            ])
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "reasoningEffort": .string("instruct")
    ]

    static func normalizedEffort(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "instruct", "chat", "none", "no_think", "off", "disabled", "false":
            return "instruct"
        case "max", "maximum":
            return "max"
        case "reasoning", "think", "thinking", "high", "medium", "low", "true":
            return "high"
        default:
            return "instruct"
        }
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
            label: L("Reasoning Effort"),
            icon: "brain",
            kind: .segmented([
                ModelOptionSegment(id: "minimal", label: L("Minimal")),
                ModelOptionSegment(id: "low", label: L("Low")),
                ModelOptionSegment(id: "medium", label: L("Medium")),
                ModelOptionSegment(id: "high", label: L("High")),
            ])
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "reasoningEffort": .string("medium")
    ]
}

// MARK: - Mistral Reasoning Profile

/// Mistral's adjustable-reasoning models (mistral-small, mistral-medium-3.5+) —
/// supports reasoning effort control via the `reasoning_effort` request field.
struct MistralReasoningProfile: ModelProfile {
    static let displayName = "Reasoning Effort"

    static func matches(modelId: String) -> Bool {
        let bare =
            modelId.lowercased().split(separator: "/").last.map(String.init)
            ?? modelId.lowercased()
        return bare.hasPrefix("mistral-small") || bare.hasPrefix("mistral-medium")
    }

    // Mistral's chat-completions `reasoning_effort` accepts only `none` and
    // `high` on mistral-small-latest / mistral-medium-3.5; `low` and `medium`
    // are rejected with HTTP 400 (`invalid_request_invalid_args`).
    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "reasoningEffort",
            label: L("Reasoning Effort"),
            icon: "brain",
            kind: .segmented([
                ModelOptionSegment(id: "none", label: L("None")),
                ModelOptionSegment(id: "high", label: L("High")),
            ])
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "reasoningEffort": .string("high")
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
            label: L("Disable Thinking"),
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

/// Nemotron-3 reasoning models — `model_type=nemotron_h` hybrid
/// Mamba+Attn+MoE bundles whose chat template reads an `enable_thinking`
/// kwarg. Osaurus exposes the toggle but does not synthesize a reasoning mode:
/// absent values must let the model bundle/runtime decide.
///
/// Match excludes `coder` variants (none ship today, but mirroring
/// `QwenThinkingProfile`'s shape for consistency if NVIDIA publishes one).
struct NemotronThinkingProfile: ModelProfile {
    static let displayName = "Nemotron Thinking"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return ModelFamilyNames.isNemotronThinkingFamily(modelId) && !lower.contains("coder")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "disableThinking",
            label: L("Disable Thinking"),
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
/// reads an `enable_thinking` Jinja kwarg. Osaurus exposes the native switch
/// while leaving absent values absent so the shipped template/runtime defaults
/// remain authoritative.
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
            label: L("Disable Thinking"),
            icon: "brain.head.profile",
            kind: .toggle(default: true)
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "disableThinking": .bool(true)
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}

// MARK: - Hy3 Reasoning Profile

/// Tencent Hunyuan v3 / Hy3 (`model_type=hy_v3`) uses a `reasoning_effort`
/// chat-template kwarg instead of the boolean `enable_thinking` convention.
/// The shipped template defaults to `no_think` and opens `<think>` only for
/// `low` / `high`, so expose the native effort values rather than mapping it
/// through the generic Disable Thinking toggle.
struct Hy3ReasoningProfile: ModelProfile {
    static let displayName = "Hy3 Reasoning"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.contains("hy3")
            || lower.contains("hy-v3")
            || lower.contains("hy_v3")
            || lower.contains("hunyuan-v3")
            || lower.contains("hunyuan_v3")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "reasoningEffort",
            label: L("Reasoning Effort"),
            icon: "brain.head.profile",
            kind: .segmented([
                ModelOptionSegment(id: "no_think", label: L("Off")),
                ModelOptionSegment(id: "low", label: L("Low")),
                ModelOptionSegment(id: "high", label: L("High")),
            ])
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "reasoningEffort": .string("no_think")
    ]

    static func normalizedEffort(_ value: String) -> String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "no_think", "none", "off", "disabled", "false":
            return "no_think"
        case "low":
            return "low"
        case "high", "medium", "max", "maximum":
            return "high"
        default:
            return "no_think"
        }
    }
}

// MARK: - Ling Runtime Profile

/// Ling-2.6 Flash (`model_type=bailing_hybrid`) uses an `enable_thinking`
/// chat-template kwarg to choose the upstream "detailed thinking on/off"
/// directive. Osaurus only forwards explicit user/API choices; this is a
/// template mode, not an output-shaping guard.
struct LingRuntimeProfile: ModelProfile {
    static let displayName = "Ling"

    static func matches(modelId: String) -> Bool {
        ModelFamilyNames.isLingFamily(modelId)
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "disableThinking",
            label: L("Disable Thinking"),
            icon: "brain.head.profile",
            kind: .toggle(default: true)
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "disableThinking": .bool(true)
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}

// MARK: - Zaya Thinking Profile

/// ZAYA1 (Zyphra; `model_type=zaya`) — hybrid CCA-attention bundles
/// (BF16 base + JANGTQ2 / JANGTQ4 / MXFP4 routed-expert variants). ZAYA is
/// reasoning-capable, but its template default is a closed/no-thinking
/// assistant prefix (`think_in_template=false`): callers may opt in with
/// `enable_thinking=true` to open a reasoning block. The profile exposes the
/// standard Disable Thinking toggle without injecting a default into requests.
struct ZayaThinkingProfile: ModelProfile {
    static let displayName = "Zaya Thinking"

    static func matches(modelId: String) -> Bool {
        ModelFamilyNames.isZayaFamily(modelId)
            && !ModelFamilyNames.isZayaVLFamily(modelId)
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "disableThinking",
            label: L("Disable Thinking"),
            icon: "brain.head.profile",
            kind: .toggle(default: true)
        )
    ]

    static let defaults: [String: ModelOptionValue] = [
        "disableThinking": .bool(true)
    ]

    static let thinkingOption: (id: String, inverted: Bool)? = ("disableThinking", true)
}

// MARK: - Gemma 4 Runtime Profile

/// Gemma-4 chat templates expose an `enable_thinking` kwarg and pipe-wrapped
/// `<|think|>` markers. Expose the same chat-input Thinking chip as other
/// local reasoning models, but do not synthesize a hidden request default:
/// omitted options still let the model bundle/runtime decide.
struct Gemma4RuntimeProfile: ModelProfile {
    static let displayName = "Gemma 4"

    static func matches(modelId: String) -> Bool {
        let lower = modelId.lowercased()
        return lower.contains("gemma-4") || lower.contains("gemma4")
    }

    static let options: [ModelOptionDefinition] = [
        ModelOptionDefinition(
            id: "disableThinking",
            label: L("Disable Thinking"),
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
            label: L("Disable Thinking"),
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
    ModelOptionSegment(id: "auto", label: L("Auto")),
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
    ModelOptionSegment(id: "auto", label: L("Auto")),
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
    ModelOptionSegment(id: "textAndImage", label: L("Text & Image")),
    ModelOptionSegment(id: "imageOnly", label: L("Image Only")),
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
            label: L("Aspect Ratio"),
            icon: "aspectratio",
            kind: .segmented(geminiExtendedAspectRatioSegments)
        ),
        ModelOptionDefinition(
            id: "imageSize",
            label: L("Resolution"),
            icon: "arrow.up.right.and.arrow.down.left",
            kind: .segmented([
                ModelOptionSegment(id: "auto", label: L("Auto")),
                ModelOptionSegment(id: "512px", label: "0.5K"),
                ModelOptionSegment(id: "1K", label: "1K"),
                ModelOptionSegment(id: "2K", label: "2K"),
                ModelOptionSegment(id: "4K", label: "4K"),
            ])
        ),
        ModelOptionDefinition(
            id: "outputType",
            label: L("Output"),
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
            label: L("Aspect Ratio"),
            icon: "aspectratio",
            kind: .segmented(geminiAspectRatioSegments)
        ),
        ModelOptionDefinition(
            id: "imageSize",
            label: L("Resolution"),
            icon: "arrow.up.right.and.arrow.down.left",
            kind: .segmented([
                ModelOptionSegment(id: "auto", label: L("Auto")),
                ModelOptionSegment(id: "1K", label: "1K"),
                ModelOptionSegment(id: "2K", label: "2K"),
                ModelOptionSegment(id: "4K", label: "4K"),
            ])
        ),
        ModelOptionDefinition(
            id: "outputType",
            label: L("Output"),
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
            label: L("Aspect Ratio"),
            icon: "aspectratio",
            kind: .segmented(geminiAspectRatioSegments)
        ),
        ModelOptionDefinition(
            id: "outputType",
            label: L("Output"),
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
            label: L("Web Search"),
            icon: "magnifyingglass",
            kind: .segmented([
                ModelOptionSegment(id: "off", label: L("Off")),
                ModelOptionSegment(id: "on", label: L("On")),
                ModelOptionSegment(id: "auto", label: L("Auto")),
            ])
        ),
        ModelOptionDefinition(
            id: "disableThinking",
            label: L("Disable Thinking"),
            icon: "brain.head.profile",
            kind: .toggle(default: true)
        ),
        ModelOptionDefinition(
            id: "includeVeniceSystemPrompt",
            label: L("Venice System Prompt"),
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
