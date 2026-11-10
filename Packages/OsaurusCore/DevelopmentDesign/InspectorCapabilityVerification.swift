#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// Original capability table; all selection callbacks stay in local view state.
/// Does not load tools, write agent policy, or request OS permissions.
struct InspectorCapabilityVerification: View {
    @Environment(\.theme) private var theme
    @State private var selected: Set<String> = ["one"]
    @State private var expanded = true
    private let tools = ["one", "two"]
    private var rows: [CapabilityRow] {
        var result: [CapabilityRow] = [.groupHeader(id: "local", name: "Local capability samples", icon: "square.stack",
            enabledCount: selected.count, totalCount: tools.count, isExpanded: expanded, status: nil)]
        if expanded {
            result += tools.map { id in .tool(id: id, name: "Local tool \(id)", description: "Local selection only; no tool runs.",
                enabled: selected.contains(id), availability: .init(toolName: id, runtime: nil, groupName: "Local samples",
                    reasonCodes: [.available], detail: "Local sample"), groupToggleLabel: nil, catalogTokens: 30, estimatedTokens: 60) }
        }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Original capability table · local selections only")
            Text("Local selected count: \(selected.count)/2")
            CapabilitiesTableRepresentable(rows: rows, theme: theme,
                onToggleGroup: { _ in expanded.toggle() },
                onEnableAllInGroup: { _ in selected = Set(tools) },
                onDisableAllInGroup: { _ in selected = [] },
                onToggleTool: { id, _ in if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } })
                .frame(height: 260)
        }
    }
}
#endif
