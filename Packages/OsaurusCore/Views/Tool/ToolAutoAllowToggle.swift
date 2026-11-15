//
//  ToolAutoAllowToggle.swift
//  osaurus
//
//  The "Auto-Allow All Tool Calls" master switch, shown at the top of
//  Tools & MCP → All Tools next to the per-tool Auto / Ask / Deny policies it
//  overrides. Moved here from the Chat tab so every tool-permission control
//  lives in one place.
//

import SwiftUI

struct ToolAutoAllowToggle: View {
    /// Bound to `UserDefaults` key `ToolApprovalSettings.autoAllowAllDefaultsKey`,
    /// read by `ToolRegistry` at each `.ask`-policy tool invocation.
    @AppStorage(ToolApprovalSettings.autoAllowAllDefaultsKey)
    private var autoAllowAllToolsEnabled: Bool = false

    /// Turning auto-allow ON disables a security gate for every tool, so the
    /// toggle's binding intercepts the off→on flip and routes it through a
    /// confirmation alert; only confirming persists the value. Turning it
    /// off applies immediately.
    @State private var showConfirm = false

    var body: some View {
        SettingsGroup {
            SettingsToggle(
                title: "Auto-Allow All Tool Calls",
                description: ToolApprovalEducation.globalToggleDescription,
                anchorId: "tools.autoAllowAll",
                isOn: binding
            )
        }
        .themedAlert(
            L("Auto-Allow All Tool Calls?"),
            isPresented: $showConfirm,
            message: ToolApprovalEducation.globalConfirmMessage,
            primaryButton: .destructive(L("Auto-Allow All")) { autoAllowAllToolsEnabled = true },
            secondaryButton: .cancel(L("Cancel"))
        )
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { autoAllowAllToolsEnabled },
            set: { isOn in
                if isOn && !autoAllowAllToolsEnabled {
                    showConfirm = true
                } else {
                    autoAllowAllToolsEnabled = isOn
                }
            }
        )
    }
}
