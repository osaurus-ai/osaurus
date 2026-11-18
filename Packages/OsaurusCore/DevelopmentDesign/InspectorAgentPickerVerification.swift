#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// Existing picker content with local choices. Rendering inline avoids LAN
/// discovery and actual workspace/agent configuration during visual checks.
struct InspectorAgentPickerVerification: View {
    private static let first = UUID(uuidString: "ABC00000-0000-4000-8000-000000000001")!
    private static let second = UUID(uuidString: "ABC00000-0000-4000-8000-000000000002")!
    private let agents = [
        Agent(id: Self.first, name: "Research assistant", description: "Local sample description"),
        Agent(id: Self.second, name: "Planning assistant with a longer name", description: "Another local choice")
    ]
    private let workspaces: [WorkspaceAgentPickerOption] = [
        .init(ref: .init(workspaceId: "inspector", agentAddress: "sample-online"), name: "Shared research agent", description: "Workspace description", workspaceName: "Sample workspace", ownerName: "Teammate", presence: .online),
        .init(ref: .init(workspaceId: "inspector", agentAddress: "sample-offline"), name: "Offline shared agent", description: nil, workspaceName: "Sample workspace", ownerName: nil, presence: .offline(lastSeen: nil)),
        .init(ref: .init(workspaceId: "inspector", agentAddress: "sample-unknown"), name: "Unknown presence agent", description: nil, workspaceName: "Sample workspace", ownerName: nil, presence: .unknown)
    ]
    @State private var variant = "Workspace targets"
    @State private var target: AgentDispatchTarget? = .local(Self.first)
    @State private var callbacks = 0
    @State private var modelOverride: String?
    @State private var spawnIDs: [UUID] = []
    @State private var workspaceIDs: [WorkspaceAgentRef] = []
    @State private var permissions = SubagentPermissionDefaults()
    @State private var budgets = SubagentBudgets()

    private var workspacePicker: AgentPicker {
        AgentPicker(selectedTarget: $target, agents: agents, workspaceAgents: workspaces)
    }
    var body: some View {
        SettingsSection(title: "Native agent/workspace picker", layout: .plain, verbatimTitle: true) {
            Picker("Picker implementation", selection: $variant) {
                Text(verbatim: "Workspace targets").tag("Workspace targets")
                Text(verbatim: "Selected fields").tag("Selected fields")
                Text(verbatim: "Delegation choices").tag("Delegation choices")
            }
            if variant == "Workspace targets" {
                workspacePicker.inspectorMenu
            } else if variant == "Delegation choices" {
                SpawnConfigurationEditor(excludedAgentID: Agent.defaultId, localHandoffEnabled: true,
                    modelOverride: $modelOverride, spawnableAgentIDs: $spawnIDs,
                    spawnableWorkspaceAgents: $workspaceIDs, permissionDefaults: $permissions,
                    budgets: $budgets, onChange: { callbacks += 1 }, inspectionDisplay: true)
            } else {
                workspacePicker
            }
            Text(verbatim: "Production views with local sample choices. No agent or workspace settings are saved. Inline menus do not start network discovery.")
                .font(SettingsFont.caption)
        }
        .onChange(of: target) { _, _ in callbacks += 1 }
    }
}
#endif
