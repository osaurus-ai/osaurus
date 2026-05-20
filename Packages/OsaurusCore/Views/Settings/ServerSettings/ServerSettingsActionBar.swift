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
    let requiresRestart: Bool
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

            Spacer(minLength: 12)

            Button(action: onReset) {
                Text("Reset", bundle: .module)
            }
            .buttonStyle(SettingsButtonStyle())
            .disabled(saving || !hasUnsavedChanges)
            .opacity(hasUnsavedChanges ? 1 : 0.5)

            Button(action: onSave) {
                HStack(spacing: 6) {
                    if saving {
                        ProgressView().scaleEffect(0.55)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(saving ? "Saving…" : "Save Changes", bundle: .module)
                }
            }
            .buttonStyle(SettingsButtonStyle(isPrimary: true))
            .disabled(saving || !hasUnsavedChanges)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(
            theme.secondaryBackground
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.cardBorder)
                        .frame(height: 1)
                }
        )
    }

    private var statusBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(hasUnsavedChanges ? theme.warningColor : theme.successColor)
                .frame(width: 7, height: 7)
            Text(
                LocalizedStringKey(
                    hasUnsavedChanges ? "Unsaved changes" : "All changes saved"
                ),
                bundle: .module
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(hasUnsavedChanges ? theme.primaryText : theme.tertiaryText)
        }
    }

    /// Inline "saving will restart the NIO server" chip, surfaced
    /// next to the unsaved indicator. Tooltip carries the full
    /// explanation so the chip itself stays compact.
    private var restartChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10, weight: .semibold))
            Text("Restart required", bundle: .module)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(theme.warningColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(theme.warningColor.opacity(0.10))
                .overlay(
                    Capsule().stroke(theme.warningColor.opacity(0.25), lineWidth: 0.5)
                )
        )
        .help(
            "Saving these changes will restart the NIO server to bind the new socket and refresh middleware."
        )
    }
}
