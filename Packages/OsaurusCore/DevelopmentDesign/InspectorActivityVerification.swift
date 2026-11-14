#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// Production native views with local disclosure state and static display data.
/// No tool execution, file mutation or model request is initiated by this route.
struct InspectorActivityVerification: View {
    @Environment(\.inspectorVerificationWidth) private var width
    @State private var streaming = false
    @State private var sample = "File tool · success and failure"
    @State private var expanded: Set<String> = []
    @State private var toolHeight: CGFloat = 180
    @State private var groupHeight: CGFloat = 100
    @Environment(\.theme) private var theme
    private let turn = UUID(uuidString: "F00D0000-0000-0000-0000-000000000034")!
    private var calls: [ToolCallItem] {
        if sample == "Search and workflow results" {
            return [
                ToolCallItem(call: .init(id: "inspector-34-search-ok", type: "function", function: .init(name: "file_search", arguments: "{\"query\":\"local sample\"}")),
                    result: ToolEnvelope.success(tool: "file_search", result: ["kind": "search", "query": "local sample", "entries": [["path": "reference.md", "type": "file"]], "truncated": true]), duration: 0.3),
                ToolCallItem(call: .init(id: "inspector-34-search-error", type: "function", function: .init(name: "web_search", arguments: "{\"query\":\"local sample\"}")),
                    result: ToolEnvelope.failure(kind: .executionError, message: "Local search provider unavailable", tool: "web_search"), duration: 0.2),
                ToolCallItem(call: .init(id: "inspector-34-workflow", type: "function", function: .init(name: "workflow_local_display", arguments: "{}")),
                    result: ToolEnvelope.success(tool: "workflow_local_display", result: ["run_id": "ABC00000-0000-4000-8000-000000000034", "status": "completed", "text": "Local workflow display result. No workflow exists or ran."]), duration: 1.2)
            ]
        }
        return
        [
            ToolCallItem(call: .init(id: "inspector-34-read", type: "function", function: .init(name: "read_file", arguments: "{\"path\":\"example.txt\"}")), result: "Read the sample document.", duration: 0.4),
            ToolCallItem(call: .init(id: "inspector-34-error", type: "function", function: .init(name: "read_file", arguments: "{\"path\":\"missing.txt\"}")), result: ToolEnvelope.failure(kind: .executionError, message: "Sample file unavailable", tool: "read_file"), duration: 0.2),
            ToolCallItem(call: .init(id: "inspector-34-running", type: "function", function: .init(name: "read_file", arguments: "{\"path\":\"notes.txt\"}")), result: streaming ? nil : "Sample notes.", duration: streaming ? nil : 0.5)
        ]
    }
    private var children: [ContentBlock] {
        [.thinking(turnId: turn, index: 0, text: "Review the supplied sample.", isStreaming: false, duration: 2, position: .first), .toolCallGroup(turnId: turn, calls: calls, position: .last)]
    }
    var body: some View {
        SettingsSection(title: "Chat · tool execution and activity", layout: .plain, verbatimTitle: true) {
            Text("Tool results appear during an agent reply. Expand rows for arguments/output; the activity rollup also includes reasoning.").font(SettingsFont.caption)
            Picker("Result format", selection: $sample) {
                Text("File tool · success and failure").tag("File tool · success and failure")
                Text("Search and workflow results").tag("Search and workflow results")
            }
            Toggle("Tool is running", isOn: $streaming)
            InspectorNativeActivity(calls: calls, children: nil, streaming: streaming, expanded: $expanded, height: $toolHeight)
                .frame(width: width, height: toolHeight)
            InspectorNativeActivity(calls: calls, children: children, streaming: streaming, expanded: $expanded, height: $groupHeight)
                .frame(width: width, height: groupHeight)
            InspectorPendingActivity().frame(width: width, height: ActivityInspectionStyle.headerHeight(theme))
            Text(verbatim: "Individual tool results, grouped activity, then a pending tool-arguments row. These are separate app configurations; no tools are run.").font(SettingsFont.caption)
        }
    }
}
private struct InspectorNativeActivity: NSViewRepresentable {
    @Environment(\.inspectorVerificationWidth) private var width
    let calls: [ToolCallItem]
    let children: [ContentBlock]?
    let streaming: Bool
    @Binding var expanded: Set<String>
    @Binding var height: CGFloat
    @Environment(\.theme) private var theme
    func makeNSView(context: Context) -> NSView { children == nil ? NativeToolCallGroupView() : NativeActivityGroupView() }
    func updateNSView(_ view: NSView, context: Context) {
        defer { view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection) }
        let toggle: (String) -> Void = { id in if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) } }
        let resized: () -> Void = { [weak view] in
            let measured = (view as? NativeToolCallGroupView)?.measuredHeight() ?? (view as? NativeActivityGroupView)?.measuredHeight() ?? 60
            if abs(measured - height) > 0.5 { DispatchQueue.main.async { height = measured } }
        }
        if let group = view as? NativeActivityGroupView, let children {
            group.configure(children: children, expandedIds: expanded, width: width, theme: theme, isStreaming: streaming, blockId: "inspector-34-activity", sessionRedactions: [:], onToggleChild: toggle, onToggle: { toggle("inspector-34-activity") }, onHeightChanged: resized)
        } else if let tools = view as? NativeToolCallGroupView {
            tools.configure(calls: calls, expandedIds: expanded, width: width, theme: theme, isStreaming: streaming, onToggle: toggle, onHeightChanged: resized)
        }
    }
}
private struct InspectorPendingActivity: NSViewRepresentable {
    @Environment(\.inspectorVerificationWidth) private var width
    @Environment(\.theme) private var theme
    func makeNSView(context: Context) -> NativePendingToolCallView { NativePendingToolCallView() }
    func updateNSView(_ view: NativePendingToolCallView, context: Context) {
        defer { view.updateCatalogInspection(context.environment.nativeCatalogInspection, selection: context.environment.nativeCatalogSelection) }
        view.configure(toolName: "read_file", argPreview: nil, argSize: 384, theme: theme)
    }
}
#endif
