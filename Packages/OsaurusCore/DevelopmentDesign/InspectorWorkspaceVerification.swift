#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

private struct InspectorWorkspaceDisplayKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var inspectorWorkspaceDisplayOnly: Bool {
        get { self[InspectorWorkspaceDisplayKey.self] }
        set { self[InspectorWorkspaceDisplayKey.self] = newValue }
    }
}

/// Workspace and sandbox components with local sample data.
struct InspectorWorkspaceVerification: View {
    @Environment(\.theme) private var theme
    @State private var events = 0
    @State private var mode = "Shared agents"
    @State private var form = "Create workspace"
    @State private var showingForm = false
    private let forms = ["Create workspace", "Activate workspace", "Join workspace", "Invite link", "Invite result", "Share agent", "Pool top-up", "Pool checkout waiting", "Pool auto-reload", "Pool activity"]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Workspace display", selection: $mode) {
                ForEach(["Shared agents", "Account forms", "Workspace cards", "Sandbox provisioning"], id: \.self) { Text($0).tag($0) }
            }
            if mode == "Shared agents" {
                WorkspaceDetailView.inspectionSharedRows { events += 1 }
            } else if mode == "Account forms" {
                Picker("Local workspace form", selection: $form) { ForEach(forms, id: \.self) { Text($0).tag($0) } }
                Button("Open local workspace form") { showingForm = true }
                Text("Sample forms for workspace setup and billing")
            } else if mode == "Workspace cards" {
                WorkspacesView.inspectionCards { events += 1 }
            } else {
                ProvisioningJourneyView.inspectionRows()
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showingForm) { localForm.environment(\.inspectorWorkspaceDisplayOnly, true) }
    }
    @ViewBuilder private var localForm: some View {
        switch form {
        case "Create workspace": CreateWorkspaceSheet.inspectionSample()
        case "Activate workspace": ActivateWorkspaceSheet.inspectionSample()
        case "Join workspace": JoinWorkspaceSheet.inspectionSample()
        case "Invite link": CreateInviteLinkSheet.inspectionSample(result: false)
        case "Invite result": CreateInviteLinkSheet.inspectionSample(result: true)
        case "Share agent": WorkspaceShareAgentSheet.inspectionSample()
        case "Pool top-up": WorkspacePoolTopUpSheet.inspectionSample(waiting: false)
        case "Pool checkout waiting": WorkspacePoolTopUpSheet.inspectionSample(waiting: true)
        case "Pool auto-reload": WorkspaceAutoReloadSheet.inspectionSample()
        default: WorkspacePoolActivityView.inspectionSample()
        }
    }
}
#endif
