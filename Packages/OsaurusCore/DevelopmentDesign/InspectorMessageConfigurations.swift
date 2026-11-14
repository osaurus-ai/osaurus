#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI
import AppKit

/// Actual transcript configurations, built by the same block generator as Chat.
/// Only callbacks/content are local; views, joining, visibility and height rules
/// are the production implementations.
struct InspectorMessageConfigurations: View {
    let isAssistant: Bool
    @Environment(\.theme) private var theme
    @Environment(\.inspectorVerificationWidth) private var width
    @Environment(\.inspectorMessageConfiguration) private var sharedConfiguration
    @State private var localConfiguration = "Text"
    @State private var text = "Can you compare these approaches and recommend a starting point?"
    @State private var saved = "Can you compare these approaches and recommend a starting point?"
    @State private var editing = false
    @State private var hovered = false
    @State private var heights: [String: CGFloat] = [:]
    init(isAssistant: Bool) {
        self.isAssistant = isAssistant
        _localConfiguration = State(initialValue: isAssistant ? "Completed reply" : "Text")
    }
    private var choices: [String] { isAssistant ? InspectorMessageExamples.assistantConfigurations : InspectorMessageExamples.userConfigurations }
    private var configuration: String { sharedConfiguration?.wrappedValue ?? localConfiguration }
    private var configurationBinding: Binding<String> { Binding(get: { selected }, set: { value in
        if let sharedConfiguration { sharedConfiguration.wrappedValue = value } else { localConfiguration = value }
    }) }
    private var selected: String { choices.contains(configuration) ? configuration : choices[0] }
    private var example: InspectorMessageExample { InspectorMessageExamples.make(assistant: isAssistant, configuration: selected, userText: saved) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if sharedConfiguration == nil {
                Picker("App configuration", selection: configurationBinding) {
                    ForEach(choices, id: \.self) { Text($0).tag($0) }
                }.fixedSize()
            }
            Text(example.usage).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(Array(example.blocks.enumerated()), id: \.element.id) { index, block in
                    InspectorTranscriptCell(block: block, previous: index > 0 ? example.blocks[index - 1] : nil,
                        next: index + 1 < example.blocks.count ? example.blocks[index + 1] : nil,
                        streaming: example.streaming, hovered: hovered, statsText: example.statsText, text: $text, editing: $editing,
                        height: Binding(get: { heights[block.id] ?? estimate(block) }, set: { heights[block.id] = $0 }),
                        onConfirm: { saved = text; editing = false },
                        onCancel: { text = saved; editing = false })
                        .frame(width: width, height: heights[block.id] ?? estimate(block))
                }
            }.id(selected).onHover { hovered = $0 }
            Text("The same message views used in Chat. Preview actions stay inside this example.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: width, alignment: .leading)
        .onChange(of: selected) { _, value in
            heights = [:]; editing = value == "Editing a sent message"
            saved = InspectorMessageExamples.userText(value); text = saved
        }
    }
    private func estimate(_ block: ContentBlock) -> CGFloat {
        NativeCellHeightEstimator.estimatedHeight(for: block, width: width, theme: theme, isExpanded: false)
    }
}
struct InspectorMessageExample {
    let blocks: [ContentBlock]
    let streaming: Bool
    let usage: String
    var statsText: String? = nil
}
@MainActor enum InspectorMessageExamples {
    static let userConfigurations = ["Text", "Long message", "With a file", "With an image", "Attachments without text", "Editing a sent message", "Channel message and warning", "Delegated task", "Scheduled message", "Watched-folder message", "Folder unavailable"]
    static let assistantConfigurations = ["Completed reply", "Formatted reply", "Streaming reply", "Waiting for the first token", "Finishing a reply", "Interrupted before a reply", "Interrupted after partial text", "No visible text", "Charged empty response", "Request failed"]
    private static let attachmentExamples = InspectorAttachmentSamples.items
    static let userID = UUID(uuidString: "ABC00000-0000-4000-8000-000000000028")!
    static let assistantID = UUID(uuidString: "ABC00000-0000-4000-8000-000000000029")!
    static let timestamp = Date(timeIntervalSince1970: 1_792_800_000)
    static func userText(_ configuration: String) -> String {
        configuration == "Long message" ? Array(repeating: "Compare the approaches against the same constraints, keep the existing behavior, and explain the tradeoffs before recommending a starting point.", count: 12).joined(separator: "\n\n") : "Can you compare these approaches and recommend a starting point?"
    }
    static func make(assistant: Bool, configuration: String, userText: String) -> InspectorMessageExample {
        if !assistant {
            let items = attachmentExamples
            let attachments: [Attachment] = configuration == "With a file" ? Array(items.filter(\.isDocument).prefix(1)) : configuration == "With an image" ? Array(items.filter(\.isImage).prefix(1)) : configuration == "Attachments without text" ? items : []
            let content = configuration == "Attachments without text" ? "" : userText
            let turn = ChatTurn(role: .user, content: content, attachments: attachments, id: userID, createdAt: timestamp)
            var blocks = ContentBlock.generateBlocks(from: [turn], streamingTurnId: nil, agentName: "Osaurus")
            if let envelope = envelope(configuration, content: content) {
                blocks = [.userMessage(turnId: userID, text: content, attachments: attachments,
                    timestamp: timestamp, responseTurnId: nil, envelope: envelope, position: .only)]
            }
            return .init(blocks: blocks, streaming: false,
                usage: "Chat · sent user message. \(configuration == "Editing a sent message" ? "The editor uses Multiline text editor; Save and Cancel use Buttons." : "Hover the message to reveal its actual actions.")")
        }
        let formatted = "## Recommendation\nStart with the shared controls, then compose them into the screen.\n\n- Preserve the existing actions.\n- Use the shared tokens.\n\n```swift\nlet approach = \"Shared components\"\n```\n\n**Next step:** compare both configurations."
        var content = "Start with the shared controls, then combine them into the screen. That keeps the same buttons and inputs consistent across the app."
        if configuration == "Formatted reply" { content = formatted }
        if ["Waiting for the first token", "Interrupted before a reply", "No visible text", "Charged empty response"].contains(configuration) { content = "" }
        if configuration == "Streaming reply" { content = "Start with the shared controls, then combine them into" }
        if configuration == "Interrupted after partial text" { content = "Start with the shared controls. The comparison also needs" }
        if configuration == "Request failed" { content = ChatErrorMessages.assistantMessage(for: URLError(.networkConnectionLost)) }
        let turn = ChatTurn(role: .assistant, content: content, id: assistantID, createdAt: timestamp)
        let streaming = ["Streaming reply", "Waiting for the first token"].contains(configuration)
        let finishing = configuration == "Finishing a reply"
        if configuration.hasPrefix("Interrupted") { turn.terminalStopReason = "cancelled" }
        if configuration == "No visible text" { turn.generationTokenCount = 0 }
        if configuration == "Charged empty response" {
            turn.routerBilling = RouterBillingSummary(costMicro: "1200", status: "completed", tokenSource: "provider", inputTokens: 180, outputTokens: 0)
        }
        if ["Completed reply", "Formatted reply"].contains(configuration) {
            turn.completedAt = timestamp.addingTimeInterval(5); turn.lastOutputAt = timestamp.addingTimeInterval(5)
            turn.generationTokenCount = 120; turn.timeToFirstToken = 0.4; turn.generationTokensPerSecond = 24
        }
        let generated = ContentBlock.generateBlocks(from: [turn], streamingTurnId: streaming ? assistantID : nil,
            activeTurnId: streaming || finishing ? assistantID : nil, agentName: "Osaurus")
        let stats = generated.compactMap { block -> String? in
            guard case let .generationStats(ttft, rate, count, unclosed, load, cached, total) = block.kind else { return nil }
            return NativeStatsView.statsText(ttft: ttft, tokensPerSecond: rate, tokenCount: count,
                unclosedReasoning: unclosed, modelLoad: load, cachedInputTokens: cached, totalDuration: total)
        }.first
        return .init(blocks: ContentBlock.tablePresentationBlocks(generated), streaming: streaming || finishing,
            usage: "Chat · agent reply. Header, body, progress/notice and actions follow the app’s actual rules for this configuration.", statsText: stats)
    }
    private static func envelope(_ configuration: String, content: String) -> DispatchEnvelope? {
        let kind: DispatchEnvelope.Kind?
        switch configuration {
        case "Channel message and warning": kind = .channel(.init(source: .parse("Slack channel design-review, sender Teammate"), risk: .suspicious, signals: [.systemInstructionOverride], content: content, attachmentLines: [], contentCharacterCount: content.count, emittedCharacterCount: content.count, truncated: false))
        case "Delegated task": kind = .delegatedTask(resuming: false)
        case "Scheduled message": kind = .selfScheduledRun(scheduledBy: "Osaurus", scheduledAt: "09:00", previousRun: nil)
        case "Watched-folder message": kind = .watcherRun(watchedFolder: "/Project", changedPaths: ["notes.txt", "reference.md"], overflowCount: 2, iteration: 3)
        case "Folder unavailable": kind = nil
        default: return nil
        }
        return DispatchEnvelope(kind: kind, folderUnreadablePath: configuration == "Folder unavailable" ? "/Project" : nil, displayText: content)
    }
}
private struct InspectorTranscriptCell: NSViewRepresentable {
    @Environment(\.theme) private var theme
    @Environment(\.inspectorVerificationWidth) private var width
    let block: ContentBlock
    let previous: ContentBlock?
    let next: ContentBlock?
    let streaming: Bool
    let hovered: Bool
    let statsText: String?
    @Binding var text: String
    @Binding var editing: Bool
    @Binding var height: CGFloat
    let onConfirm: () -> Void
    let onCancel: () -> Void
    func makeNSView(context: Context) -> NativeMessageCellView { NativeMessageCellView(frame: .zero) }
    func updateNSView(_ view: NativeMessageCellView, context: Context) {
        var rendering = CellRenderingContext(width: width, agentName: "Osaurus", agentAvatar: nil,
            agentCustomAvatarPath: nil, isStreaming: streaming, lastAssistantTurnId: block.role == .assistant ? block.turnId : nil,
            theme: theme, expandedIds: [], onToggleExpand: { _ in })
        func paragraph(_ candidate: ContentBlock?) -> Bool {
            guard let candidate, candidate.turnId == block.turnId, case .paragraph(_, _, _, .assistant) = candidate.kind else { return false }; return true
        }
        if paragraph(block) { rendering.bubbleJoinsPrevious = paragraph(previous); rendering.bubbleJoinsNext = paragraph(next) }
        rendering.isTurnHovered = hovered
        rendering.editingTurnId = editing && block.role == .user ? block.turnId : nil
        rendering.editText = ({ text }, { text = $0 })
        rendering.onConfirmEdit = onConfirm; rendering.onCancelEdit = onCancel
        rendering.onEdit = { _ in
            if case let .userMessage(original, _, _, _, _, _) = block.kind { text = original }
            editing = true
        }
        rendering.onCopy = { _ in }; rendering.onRegenerate = { _ in }; rendering.onDelete = { _ in }
        rendering.onSpeak = { _ in }; rendering.onDeleteMessage = { _ in }
        rendering.onDocumentPreview = { _ in }; rendering.onUserImagePreview = { _ in }
        rendering.responseStatsForTurn = { _ in statsText }
        rendering.onHeightMeasured = { value, _ in
            guard value.isFinite, abs(value - height) > 0.5 else { return }
            DispatchQueue.main.async { height = max(1, value) }
        }
        view.configure(block: block, context: rendering)
        view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection)
    }
}
private struct InspectorMessageConfigurationKey: EnvironmentKey {
    static var defaultValue: Binding<String>? { nil }
}
extension EnvironmentValues {
    var inspectorMessageConfiguration: Binding<String>? {
        get { self[InspectorMessageConfigurationKey.self] }
        set { self[InspectorMessageConfigurationKey.self] = newValue }
    }
}
#endif
