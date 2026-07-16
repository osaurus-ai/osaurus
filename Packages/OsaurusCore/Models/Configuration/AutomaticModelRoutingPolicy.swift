//
//  AutomaticModelRoutingPolicy.swift
//  OsaurusCore
//
//  Explicit, hardware-safe automatic routing for agent chat.
//

import Foundation

/// Resolves an agent's explicit "Automatic" model setting to a concrete
/// on-device chat model. Cloud providers are deliberately excluded: choosing
/// Automatic must not silently change privacy or incur usage charges.
enum AutomaticModelRoutingPolicy {
    /// Persisted in the existing default-model field. The value is namespaced
    /// so it cannot collide with a provider's ordinary `auto` model slug.
    static let modelId = "osaurus-internal/automatic-on-device"

    struct Requirements: OptionSet, Hashable, Sendable {
        let rawValue: UInt8

        static let image = Requirements(rawValue: 1 << 0)
        static let video = Requirements(rawValue: 1 << 1)
        static let audio = Requirements(rawValue: 1 << 2)

        static let text: Requirements = []

        init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        init(attachments: [Attachment]) {
            var value: Requirements = .text
            if attachments.hasImages { value.insert(.image) }
            if attachments.hasVideos { value.insert(.video) }
            if attachments.hasAudios { value.insert(.audio) }
            self = value
        }

        var label: String {
            var labels: [String] = []
            if contains(.image) { labels.append("image") }
            if contains(.video) { labels.append("video") }
            if contains(.audio) { labels.append("audio") }
            return labels.isEmpty ? "text" : labels.joined(separator: " + ")
        }
    }

    struct Decision: Equatable, Sendable {
        let modelId: String
        let displayName: String
        let requirements: Requirements
        let explanation: String
    }

    static func isAutomatic(_ model: String?) -> Bool {
        model?.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(modelId) == .orderedSame
    }

    /// Pick the strongest safely fitting installed model. A currently selected
    /// safe model wins when it still satisfies the turn, preventing gratuitous
    /// model churn (and preserving multi-turn cache locality). A vision turn may
    /// upgrade a text-only route to a local VLM. Tight/too-large models never
    /// route automatically; users can still choose them explicitly.
    static func resolve(
        items: [ModelPickerItem],
        requirements: Requirements = .text,
        currentModelId: String? = nil,
        physicalMemoryGB: Double = GPUMemoryBudget.hostPhysicalMemoryGB
    ) -> Decision? {
        let localCandidates = items.filter { item in
            guard item.id != modelId else { return false }
            guard case .local = item.source else { return false }
            guard item.isLikelyChatCapable else { return false }
            guard item.hardwareCompatibility == .compatible else { return false }
            return item.supports(requirements)
        }

        if let currentModelId,
            let current = localCandidates.first(where: { $0.id == currentModelId })
        {
            return decision(
                for: current,
                requirements: requirements,
                physicalMemoryGB: physicalMemoryGB
            )
        }

        if let selected = strongest(in: localCandidates) {
            return decision(
                for: selected,
                requirements: requirements,
                physicalMemoryGB: physicalMemoryGB
            )
        }

        // Apple's Foundation model is on-device and safe, but text-only. It is
        // the honest last resort when no installed MLX model has a safe route.
        if requirements.isEmpty,
            let foundation = items.first(where: {
                if case .foundation = $0.source {
                    return $0.id != modelId && $0.isLikelyChatCapable
                }
                return false
            })
        {
            return Decision(
                modelId: foundation.id,
                displayName: foundation.displayName,
                requirements: requirements,
                explanation: "On-device fallback · no installed local model has a safe measured fit"
            )
        }
        return nil
    }

    /// Media the Automatic composer may advertise. Each flag is granted only
    /// when the policy can name a concrete compatible on-device route for that
    /// modality; a text route never causes unsupported media controls to appear.
    static func availableMediaCapabilities(
        items: [ModelPickerItem],
        physicalMemoryGB: Double = GPUMemoryBudget.hostPhysicalMemoryGB
    ) -> ModelMediaCapabilities.Capabilities {
        ModelMediaCapabilities.Capabilities(
            supportsImage: resolve(
                items: items,
                requirements: .image,
                physicalMemoryGB: physicalMemoryGB
            ) != nil,
            supportsVideo: resolve(
                items: items,
                requirements: .video,
                physicalMemoryGB: physicalMemoryGB
            ) != nil,
            supportsAudio: resolve(
                items: items,
                requirements: .audio,
                physicalMemoryGB: physicalMemoryGB
            ) != nil
        )
    }

    static func failureExplanation(for requirements: Requirements) -> String {
        if requirements.isEmpty {
            return "No installed on-device chat model fits this Mac's recommended local-model budget."
        }
        return
            "No installed on-device model supports \(requirements.label) input and fits this Mac's recommended local-model budget."
    }

    private static func strongest(in candidates: [ModelPickerItem]) -> ModelPickerItem? {
        candidates.max { lhs, rhs in
            let leftParameters = parameterBillions(lhs.parameterCount) ?? 0
            let rightParameters = parameterBillions(rhs.parameterCount) ?? 0
            if leftParameters != rightParameters { return leftParameters < rightParameters }
            let left = lhs.estimatedMemoryGB ?? 0
            let right = rhs.estimatedMemoryGB ?? 0
            if left != right { return left < right }
            if lhs.defaultChatSelectionRank != rhs.defaultChatSelectionRank {
                return lhs.defaultChatSelectionRank > rhs.defaultChatSelectionRank
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedDescending
        }
    }

    /// Catalog parameter strings are display metadata (for example `27B`,
    /// `1.7B`, or `350M`). Prefer the larger capable model before using working
    /// set as a tiebreak, which avoids treating a better 1-bit model as weaker
    /// merely because its quantization is smaller on disk/in memory.
    private static func parameterBillions(_ value: String?) -> Double? {
        guard let value else { return nil }
        let normalized = value.uppercased()
        let number = normalized.prefix { $0.isNumber || $0 == "." }
        guard let parsed = Double(number) else { return nil }
        if normalized.contains("B") { return parsed }
        if normalized.contains("M") { return parsed / 1_000 }
        return nil
    }

    private static func decision(
        for item: ModelPickerItem,
        requirements: Requirements,
        physicalMemoryGB: Double
    ) -> Decision {
        let fit =
            ModelHardwareGuidance.fitSummary(
                estimatedMemoryGB: item.estimatedMemoryGB,
                compatibility: item.hardwareCompatibility,
                physicalMemoryGB: physicalMemoryGB
            ) ?? "On-device model"
        let capability =
            requirements.isEmpty
            ? "Private on-device route"
            : "On-device \(requirements.label) route"
        return Decision(
            modelId: item.id,
            displayName: item.displayName,
            requirements: requirements,
            explanation: "\(capability) · \(fit)"
        )
    }
}
