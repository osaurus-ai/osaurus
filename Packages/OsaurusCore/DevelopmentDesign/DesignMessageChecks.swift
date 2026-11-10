#if OSAURUS_DESIGN_INSPECTOR
import Foundation

@MainActor enum DesignMessageChecks {
    static func run(_ store: DesignWorkingStore) throws -> [String: Bool] {
        var result: [String: Bool] = [:]
        let baseline = store.document
        func example(_ configuration: String, assistant: Bool = true) -> InspectorMessageExample {
            InspectorMessageExamples.make(assistant: assistant, configuration: configuration, userText: InspectorMessageExamples.userText(configuration))
        }
        func hasHeader(_ e: InspectorMessageExample) -> Bool { e.blocks.contains { if case .header = $0.kind { return true }; return false } }
        func hasActions(_ e: InspectorMessageExample) -> Bool { e.blocks.contains { if case .assistantActions = $0.kind { return true }; return false } }
        result["messagesCompletedIncludesHeaderBodyActions"] = hasHeader(example("Completed reply")) && hasActions(example("Completed reply")) && example("Completed reply").blocks.contains { if case .paragraph = $0.kind { return true }; return false }
        result["messagesAllAgentConfigurationsUseActualBuilder"] = InspectorMessageExamples.assistantConfigurations.allSatisfy { hasHeader(example($0)) }
        result["messagesNormalStatisticsUseMoreMenu"] = !example("Completed reply").blocks.contains { if case .generationStats = $0.kind { return true }; return false } && example("Completed reply").statsText?.isEmpty == false
        result["messagesStreamingOmitsCompletedActions"] = !hasActions(example("Streaming reply"))
        result["messagesWaitingUsesActualIndicator"] = example("Waiting for the first token").blocks.contains { if case .typingIndicator(.generating) = $0.kind { return true }; return false }
        result["messagesFinishingUsesActualIndicator"] = example("Finishing a reply").blocks.contains { if case .typingIndicator(.finishing) = $0.kind { return true }; return false }
        result["messagesInterruptedUsesActualNoticeText"] = example("Interrupted before a reply").blocks.contains { if case .paragraph(_, let text, false, .assistant) = $0.kind { return !text.isEmpty }; return false }
        result["messagesChargedEmptyUsesActualRetryNotice"] = example("Charged empty response").blocks.contains { if case .emptyResponseNotice = $0.kind { return true }; return false }
        result["messagesLongUserContentExists"] = example("Long message", assistant: false).blocks.contains { if case .userMessage(let text, _, _, _, _, _) = $0.kind { return text.count > 1000 }; return false }
        result["messagesFileAttachmentExists"] = example("With a file", assistant: false).blocks.contains { if case .userMessage(_, let items, _, _, _, _) = $0.kind { return items.contains(where: \.isDocument) }; return false }
        result["messagesImageAttachmentExists"] = example("With an image", assistant: false).blocks.contains { if case .userMessage(_, let items, _, _, _, _) = $0.kind { return items.contains(where: \.isImage) }; return false }
        result["messagesAttachmentsOnlyExists"] = example("Attachments without text", assistant: false).blocks.contains { if case .userMessage(let text, let items, _, _, _, _) = $0.kind { return text.isEmpty && !items.isEmpty }; return false }
        result["messagesDispatchUsesActualEnvelope"] = example("Channel message and warning", assistant: false).blocks.contains { if case .userMessage(_, _, _, _, let envelope, _) = $0.kind { return envelope != nil }; return false }
        for family in [28, 29] {
            let width = "component.library.\(family).elements.container.borderWidth"
            let color = "component.library.\(family).elements.container.border"
            result["messagesNoInventedDefaultBorder_\(family)"] = !MessageBubbleInspectionStyle.hasBorderOverride(family, snapshot: try store.makeSnapshot(baseline))
            var explicit = baseline
            explicit.explicitAssignments = (explicit.explicitAssignments ?? []).union([width])
            result["messagesExplicitBorderPreserved_\(family)"] = MessageBubbleInspectionStyle.hasBorderOverride(family, snapshot: try store.makeSnapshot(explicit))
            var previousEdit = baseline
            previousEdit.mappings[color] = "color.border.strong"
            result["messagesPriorBorderEditPreserved_\(family)"] = MessageBubbleInspectionStyle.hasBorderOverride(family, snapshot: try store.makeSnapshot(previousEdit))
        }
        var old = baseline
        let layoutKeys = old.mappings.keys.filter { $0.hasPrefix("component.library.28.elements.layout.") || $0.hasPrefix("component.library.29.elements.layout.") }
        for key in layoutKeys { old.mappings.removeValue(forKey: key) }
        old.mappings["component.library.28.elements.container.gap"] = "space.24"
        old.mappings["component.library.29.elements.container.gap"] = "space.16"
        let migrated = CatalogElementAssignments.migrate(old)
        result["messagesLayoutPreservesAllSavedStyles"] = migrated.tokens == old.tokens && migrated.colorAliases == old.colorAliases && migrated.primitives == old.primitives && old.mappings.allSatisfy { migrated.mappings[$0.key] == $0.value }
        result["messagesLayoutInheritsSavedSpacing"] = migrated.mappings["component.library.28.elements.layout.topGap"] == "space.24" && migrated.mappings["component.library.28.elements.layout.attachmentTextGap"] == "space.24" && migrated.mappings["component.library.29.elements.layout.actionsGap"] == "space.16"
        return result
    }
}
#endif
