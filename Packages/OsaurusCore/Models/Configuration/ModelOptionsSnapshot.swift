//
//  ModelOptionsSnapshot.swift
//  osaurus
//
//  The composer picker's "Model Options" section as data, for the paired
//  phone (docs/MOBILE_PROTOCOL.md §12.3). Mirrors FloatingInputCard's
//  `modelPickerOptionsControl`: the semantic Thinking row, then every other
//  option the model's profile or live catalog exposes. Reads and writes the
//  same per-model `ModelOptionsStore` the Mac composer does, which is also
//  what ChatEngine applies to agent runs.
//

import Foundation

struct ModelOptionsSnapshot: Encodable, Equatable {
    struct Thinking: Encodable, Equatable {
        /// Effective state: the explicit choice, else the model's default.
        let enabled: Bool
        /// Whether an explicit choice is stored (false shows "Default").
        let explicit: Bool
        /// Offers Default / On / Off rather than a plain switch.
        let tristate: Bool
    }

    struct Segment: Encodable, Equatable {
        let id: String
        let label: String
        /// Catalog copy for an effort level, when the provider publishes it.
        let description: String?
    }

    struct Option: Encodable, Equatable {
        let id: String
        let label: String
        let icon: String?
        let help: String?
        /// `segmented | toggle`
        let kind: String
        let segments: [Segment]?
        /// Effective segment id (segmented).
        let selected: String?
        /// Effective state (toggle).
        let on: Bool?
        let explicit: Bool
    }

    let model: String
    let thinking: Thinking?
    let options: [Option]

    /// Option id the phone sends to set the semantic Thinking row.
    static let thinkingOptionId = "thinking"

    enum ApplyError: Error {
        case unknownOption
        case invalidValue
    }

    /// Built after `LocalReasoningCapability.resolveForDispatch` so local
    /// bundles report their real thinking / effort contract, not the cold
    /// main-thread miss.
    @MainActor
    static func make(for model: String) -> ModelOptionsSnapshot {
        let values = ModelProfileRegistry.normalizedOptions(
            for: model,
            persisted: ModelOptionsStore.shared.loadOptions(for: model)
        )
        let capabilities = reasoningCapabilities(for: model)
        let thinkingId = ModelProfileRegistry.profile(for: model)?.thinkingOption?.id
        let definitions = ModelProfileRegistry.options(for: model)

        var thinking: Thinking?
        if let thinkingId, definitions.contains(where: { $0.id == thinkingId }) {
            let capability = LocalReasoningCapability.capability(forModelId: model)
            // Phone chats run as agent chats, so the agent reasoning default
            // applies, as it does in a tool-capable Mac chat.
            thinking = Thinking(
                enabled: AgentReasoningPolicy.effectiveEnableThinkingForPresentation(
                    isAgentOrToolRequest: true,
                    modelOptions: values,
                    capability: capability
                ),
                explicit: ModelProfileRegistry.thinkingEnabled(for: model, values: values) != nil,
                tristate: capability.preservesOmittedThinking
            )
        }

        // Display-only defaults: the catalog default for effort, otherwise
        // the static profile's.
        var defaults = ModelProfileRegistry.defaults(for: model)
        if let capabilities {
            defaults = [:]
            if let level = capabilities.defaultLevelId {
                defaults["reasoningEffort"] = .string(level)
            }
        }

        let options = definitions.filter { $0.id != thinkingId }.map { definition -> Option in
            let explicit = values[definition.id] != nil
            switch definition.kind {
            case .segmented(let segments):
                let levels = definition.id == "reasoningEffort" ? capabilities?.levels : nil
                return Option(
                    id: definition.id,
                    label: definition.label,
                    icon: definition.icon,
                    help: definition.help,
                    kind: "segmented",
                    segments: segments.map { segment in
                        Segment(
                            id: segment.id,
                            label: segment.label,
                            description: levels?.first { $0.id == segment.id }?.description
                        )
                    },
                    selected: values[definition.id]?.stringValue
                        ?? defaults[definition.id]?.stringValue
                        ?? segments.first?.id,
                    on: nil,
                    explicit: explicit
                )
            case .toggle(let defaultValue):
                return Option(
                    id: definition.id,
                    label: definition.label,
                    icon: definition.icon,
                    help: definition.help,
                    kind: "toggle",
                    segments: nil,
                    selected: nil,
                    on: values[definition.id]?.boolValue
                        ?? defaults[definition.id]?.boolValue
                        ?? defaultValue,
                    explicit: explicit
                )
            }
        }
        return ModelOptionsSnapshot(model: model, thinking: thinking, options: options)
    }

    /// Stores one choice the way the Mac composer's picker rows do. A nil
    /// value removes the override so the model's default applies again.
    @MainActor
    static func apply(model: String, optionId: String, value: ModelOptionValue?) throws {
        var updated = ModelProfileRegistry.normalizedOptions(
            for: model,
            persisted: ModelOptionsStore.shared.loadOptions(for: model)
        )
        let thinkingOption = ModelProfileRegistry.profile(for: model)?.thinkingOption
        if optionId == thinkingOptionId {
            guard let thinkingOption else { throw ApplyError.unknownOption }
            if let value {
                guard let enabled = value.boolValue,
                    let stored = ModelProfileRegistry.thinkingStoredOption(for: model, enabled: enabled)
                else { throw ApplyError.invalidValue }
                updated[stored.id] = stored.value
            } else {
                updated.removeValue(forKey: thinkingOption.id)
            }
        } else {
            guard optionId != thinkingOption?.id,
                let definition = ModelProfileRegistry.options(for: model).first(where: { $0.id == optionId })
            else { throw ApplyError.unknownOption }
            if let value {
                switch definition.kind {
                case .segmented(let segments):
                    guard let id = value.stringValue, segments.contains(where: { $0.id == id })
                    else { throw ApplyError.invalidValue }
                case .toggle:
                    guard value.boolValue != nil else { throw ApplyError.invalidValue }
                }
                updated[optionId] = value
            } else {
                updated.removeValue(forKey: optionId)
            }
            if optionId == "reasoningEffort" {
                updated.removeValue(forKey: "disableThinking")
            }
        }
        ModelOptionsStore.shared.saveOptions(updated, for: model)
        NotificationCenter.default.post(name: .modelOptionsChanged, object: model)
    }

    /// Picker-item capabilities first (Codex catalog, official GPT ids),
    /// then the registry (local bundles' declared effort), as the composer.
    @MainActor
    private static func reasoningCapabilities(for model: String) -> ModelReasoningCapabilities? {
        if let capabilities = ModelPickerItemCache.shared.items.first(where: { $0.id == model })?
            .reasoningCapabilities, !capabilities.isEmpty
        {
            return capabilities
        }
        guard let declared = ModelProfileRegistry.reasoningCapabilities(for: model), !declared.isEmpty
        else { return nil }
        return declared
    }
}

extension Notification.Name {
    /// A model's stored options changed outside the composer (the paired
    /// phone). `object` is the model id.
    static let modelOptionsChanged = Notification.Name("modelOptionsChanged")
}
