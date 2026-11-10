#if OSAURUS_DESIGN_INSPECTOR
import SwiftUI

/// Existing production prompt views with local answers or noninteractive
/// display data. Never mounts a permission queue or submits a secret.
struct InspectorPromptVerification: View {
    @Environment(\.theme) private var theme
    @Environment(\.inspectorVerificationWidth) private var width
    @State private var mode = 0
    @State private var generation = 0
    @State private var feedback = "Local sample answers appear here."

    var body: some View {
        let _ = theme.inspectionRevision
        SettingsSection(title: "Chat · requests for your input", layout: .plain, verbatimTitle: true) {
            Picker("Prompt type", selection: $mode) {
                Text("Clarification · free text").tag(0)
                Text("Clarification · single choice").tag(1)
                Text("Clarification · multiple choice").tag(2)
                Text("Secret request").tag(3)
                Text("Computer-action confirmation").tag(4)
                Text("Cloud consent").tag(5)
                Text("Configuration-plan approval").tag(6)
            }.pickerStyle(.menu)
            Button("Reset preview") { generation += 1; feedback = "Local sample answers appear here." }
            Group {
                switch mode {
                case 0...2:
                    ClarifyPromptOverlay.inspectionCard(mode: mode) { feedback = "Local answer: " + $0 }
                        .fixedSize(horizontal: false, vertical: true)
                case 3:
                    SecretPromptOverlay.inspectionCard()
                        .fixedSize(horizontal: false, vertical: true)
                case 4: ComputerUseConfirmOverlay.inspectionCard(consent: false) { feedback = "Local display action: " + $0 }
                case 5: ComputerUseConfirmOverlay.inspectionCard(consent: true) { feedback = "Local display action: " + $0 }
                default: ConfigApprovalModal.inspectionPlan()
                }
            }.id("\(mode)-\(generation)").frame(width: min(720, width))
            Text("Existing production views. Approval, configuration and secret samples are display only; no permission, credential, configuration or agent operation is performed.")
                .font(SettingsFont.caption)
        }
    }
}
#endif
