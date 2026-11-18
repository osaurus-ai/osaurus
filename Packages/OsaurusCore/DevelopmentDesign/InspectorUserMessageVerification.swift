#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// The existing native message cell/editor; save records a local callback
/// instead of regenerating an actual conversation.
struct InspectorUserMessageVerification: View {
    @Environment(\.inspectorVerificationWidth) private var width
    var isAssistant = false
    var richText = false
    @State private var streaming = false
    @State private var text = "A local user message for checking the existing native bubble.\nSecond line with a [sample link](https://example.com)."
    @State private var saved = "A local user message for checking the existing native bubble.\nSecond line with a [sample link](https://example.com)."
    @State private var editing = false
    @State private var height: CGFloat = 200
    @State private var saves = 0
    @State private var cancels = 0
    @State private var provenance = "Ordinary"
    @State private var joined = false
    @State private var stage = 0
    @State private var joinedHeights: [CGFloat] = [180, 200, 180]
    init(isAssistant: Bool = false, richText: Bool = false) {
        self.isAssistant = isAssistant
        self.richText = richText
        let richSample = "## Rich-text heading\nParagraph with **body emphasis**, *italic*, a [sample link](https://example.com), and `inline code`.\n\n> A quoted observation.\n\n- First list item\n- Second list item\n\n| Option | Result |\n| --- | --- |\n| Native | Connected |\n| SwiftUI | Same styles |"
        let sample = richText ? richSample : isAssistant
            ? "A local assistant response for checking the existing native body.\nSecond line with **emphasis** and a [sample link](https://example.com)."
            : "A local user message for checking the existing native bubble.\nSecond line with a [sample link](https://example.com)."
        _text = State(initialValue: sample)
        _saved = State(initialValue: sample)
    }
    @ViewBuilder var body: some View {
        if !richText { InspectorMessageConfigurations(isAssistant: isAssistant) } else {
        SettingsSection(title: richText ? "Existing rich-text renderers" : isAssistant ? "Native assistant message" : "Native user message", layout: .plain, verbatimTitle: true) {
            Text(verbatim: "Verification content width: \(Int(width)) pt").font(SettingsFont.caption)
            if isAssistant {
                Toggle("Local streaming state", isOn: $streaming)
                Toggle("Joined assistant blocks", isOn: $joined)
                if joined { Picker("Local stream stage", selection: $stage) {
                    ForEach(0..<4) { Text(["First block streaming", "Code block streaming", "Last block streaming", "All blocks complete"][$0]).tag($0) }
                } }
            } else {
                Picker("Message provenance", selection: $provenance) {
                    ForEach(["Ordinary", "Channel and warnings", "Delegated task", "Scheduled", "Watcher", "Folder unreadable"], id: \.self) { Text($0) }
                }
            }
            if !isAssistant { Text(verbatim: "Local saves: \(saves); cancels: \(cancels); editing: \(editing)") }
            if joined && isAssistant {
                VStack(spacing: 0) {
                    ForEach(0..<min(stage + 1, 3), id: \.self) { index in
                        InspectorUserMessageCell(isAssistant: true, streaming: stage == index, text: $text,
                            saved: ["A first paragraph with **emphasis** and a deliberate line break.\nThe original native renderer joins adjacent blocks.", "```swift\nlet localSample = true\nprint(localSample)\n```", "## Final paragraph\n\n- First result\n- Second result\n\nThe completed local response remains visible."][index],
                            editing: $editing, height: Binding(get: { joinedHeights[index] }, set: { joinedHeights[index] = $0 }),
                            onConfirm: {}, onCancel: {}, blockIndex: index, blockCount: min(stage + 1, 3))
                            .frame(width: width, height: joinedHeights[index])
                    }
                }
            } else {
            InspectorUserMessageCell(isAssistant: isAssistant, streaming: streaming, text: $text, saved: saved, editing: $editing, height: $height,
                onConfirm: { saved = text; editing = false; saves += 1 },
                onCancel: { text = saved; editing = false; cancels += 1 }, envelope: envelope)
                .frame(width: width, height: height)
            }
            if richText {
                Text(verbatim: "Existing SwiftUI markdown path").font(SettingsFont.rowTitle)
                MarkdownMessageView(text: saved, baseWidth: width).frame(width: width)
                    .nativeCatalogTarget(["heading", "text", "code", "foreground", "accent", "border", "borderWidth", "radius", "padding", "gap"].map { CatalogElementAssignments.routed("component.library.31." + $0, mappings: DesignThemeOverlay.shared.current()?.document.mappings ?? [:]) }, "Rich-text content region")
            }
            Text(verbatim: isAssistant ? "Production native assistant renderer. Streaming state is local; no model request is made." : "Production native cell and inline editor. Save only updates this local sample; no model request is made.")
                .font(SettingsFont.caption)
        }
    }
        }
    private var envelope: DispatchEnvelope? {
        let content = "Local provenance sample. This text is displayed by the original user-message cell; no channel, schedule or agent run exists."
        let kind: DispatchEnvelope.Kind?
        switch provenance {
        case "Channel and warnings":
            kind = .channel(.init(source: .parse("Slack channel design-review, sender Local teammate"), risk: .suspicious,
                signals: [.systemInstructionOverride], content: content, attachmentLines: ["local-reference.txt"],
                contentCharacterCount: 500, emittedCharacterCount: content.count, truncated: true))
        case "Delegated task": kind = .delegatedTask(resuming: false)
        case "Scheduled": kind = .selfScheduledRun(scheduledBy: "Local display", scheduledAt: "Tomorrow at 09:00", previousRun: nil)
        case "Watcher": kind = .watcherRun(watchedFolder: "/local/sample", changedPaths: ["notes.txt", "reference.md"], overflowCount: 2, iteration: 3)
        case "Folder unreadable": kind = nil
        default: return nil
        }
        return DispatchEnvelope(kind: kind, folderUnreadablePath: provenance == "Folder unreadable" ? "/local/unavailable" : nil, displayText: content)
    }
}
private struct InspectorUserMessageCell: NSViewRepresentable {
    @Environment(\.inspectorVerificationWidth) private var width
    @Environment(\.theme) private var theme
    var isAssistant = false
    var streaming = false
    @Binding var text: String
    let saved: String
    @Binding var editing: Bool
    @Binding var height: CGFloat
    let onConfirm: () -> Void
    let onCancel: () -> Void
    var envelope: DispatchEnvelope? = nil
    var blockIndex = 0
    var blockCount = 1
    private static let turn = UUID(uuidString: "ABC00000-0000-4000-8000-000000000028")!
    func makeNSView(context: Context) -> NativeMessageCellView { NativeMessageCellView(frame: .zero) }
    func updateNSView(_ view: NativeMessageCellView, context: Context) {
        defer { view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection) }
        let kind: ContentBlockKind = isAssistant ? .paragraph(index: blockIndex, text: saved, isStreaming: streaming, role: .assistant)
            : .userMessage(text: saved, attachments: [], timestamp: Date(timeIntervalSince1970: 0), responseTurnId: nil, envelope: envelope)
        let block = ContentBlock(id: isAssistant ? "inspector-native-assistant-29-\(blockIndex)" : "inspector-native-user-28", turnId: Self.turn, kind: kind,
            position: blockCount == 1 ? .only : blockIndex == 0 ? .first : blockIndex == blockCount - 1 ? .last : .middle)
        var rendering = CellRenderingContext(width: width, agentName: "Local sample", agentAvatar: nil,
            agentCustomAvatarPath: nil, isStreaming: streaming, lastAssistantTurnId: nil, theme: theme,
            expandedIds: [], onToggleExpand: { _ in })
        rendering.isTurnHovered = true
        rendering.bubbleJoinsPrevious = blockIndex > 0
        rendering.bubbleJoinsNext = blockIndex < blockCount - 1
        rendering.editingTurnId = editing ? Self.turn : nil
        rendering.editText = ({ text }, { text = $0 })
        rendering.onConfirmEdit = onConfirm
        rendering.onCancelEdit = onCancel
        rendering.onEdit = { _ in editing = true }
        rendering.onHeightMeasured = { value, _ in
            guard abs(value - height) > 0.5 else { return }
            DispatchQueue.main.async { height = value }
        }
        view.configure(block: block, context: rendering)
    }
}
#endif
