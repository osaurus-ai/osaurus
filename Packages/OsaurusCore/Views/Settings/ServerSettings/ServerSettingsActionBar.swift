//
//  ServerSettingsActionBar.swift
//  osaurus
//
//  Sticky bottom action bar for the Server → Settings tab. Replaces
//  the old sidebar-footer Save / Reset so the affordance is always
//  visible in the user's eye line regardless of how deep they've
//  scrolled. The unsaved-changes indicator lives here too so its
//  state and the actions live on the same row.
//

import SwiftUI

struct ServerSettingsActionBar: View {
    let hasUnsavedChanges: Bool
    let hasBlockingIssues: Bool
    let requiresRestart: Bool
    let requiresModelReload: Bool
    let saving: Bool
    let onSave: () -> Void
    let onReset: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            statusBadge

            if requiresRestart {
                restartChip
            }
            if requiresModelReload {
                modelReloadChip
            }

            Spacer(minLength: 12)

            Button(action: onReset) {
                Text("Reset", bundle: .module)
            }
            .assignedSettingsButtonStyle()
            .disabled(saving || !hasUnsavedChanges)
            .opacity(hasUnsavedChanges ? 1 : 0.5)

            Button(action: onSave) {
                HStack(spacing: 6) {
                    if saving {
                        ProgressView().scaleEffect(0.55)
                    } else {
                        Image(systemName: "checkmark")
                            .glyphSize(10, weight: .semibold)
                    }
                    Text(saving ? "Saving…" : "Save Changes", bundle: .module)
                }
            }
            .assignedSettingsButtonStyle(.primary)
            .disabled(saving || !hasUnsavedChanges || hasBlockingIssues)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, theme.space.s24)
        .padding(.vertical, theme.space.s12)
        .frame(maxWidth: .infinity)
        .background(
            theme.surface.subtle
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.border.default)
                        .frame(height: 1)
                }
        )
    }

    private var statusBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(hasUnsavedChanges ? theme.status.warning.foreground : theme.status.success.foreground)
                .frame(width: 7, height: 7)
            Text(
                LocalizedStringKey(
                    hasUnsavedChanges ? "Unsaved changes" : "All changes saved"
                ),
                bundle: .module
            )
            .textStyle(.caption, weight: 500)
            .foregroundColor(hasUnsavedChanges ? theme.text.primary : theme.text.tertiary)
        }
    }

    /// Inline "saving will restart the NIO server" chip, surfaced
    /// next to the unsaved indicator. Tooltip carries the full
    /// explanation so the chip itself stays compact.
    private var restartChip: some View {
        StatusChip(L("Restart required"), tone: .warning, icon: "arrow.triangle.2.circlepath")
            .help(
                "Saving these changes will restart the NIO server to bind the new socket and refresh middleware."
            )
    }

    /// Container-owned cache and Memory Safety inputs are captured at model
    /// load. Say what Save will do instead of presenting these controls as
    /// live mutation.
    private var modelReloadChip: some View {
        StatusChip(L("Models reload after Save"), tone: .warning, icon: "arrow.clockwise.circle")
            .help(
                "Saving unloads resident local models whose cache or Memory Safety policy changed. The next request reloads them with the saved policy."
            )
    }
}
