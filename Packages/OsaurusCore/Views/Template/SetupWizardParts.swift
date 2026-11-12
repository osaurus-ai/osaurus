//
//  SetupWizardParts.swift
//  osaurus
//
//  Pieces both setup wizards share (agent and workflow): the step rail,
//  done and issue banners, inline action buttons, and the permissions
//  step. Each wizard owns its own steps and what they edit.
//

import AppKit
import SwiftUI

enum SetupStepState {
    case done, required, optional
    /// Review and other steps with nothing to check.
    case none
}

/// The numbered step list down a wizard's left edge.
struct SetupStepRail<Step: Hashable>: View {
    @Environment(\.theme) private var theme
    let steps: [Step]
    @Binding var current: Step
    var glowing: Step?
    let title: (Step) -> String
    let state: (Step) -> SetupStepState

    var body: some View {
        ScrollView(.vertical) {
            rail.padding(theme.space.s12)
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.surface.subtle)
    }

    private var rail: some View {
        VStack(alignment: .leading, spacing: theme.space.s4) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                let status = state(step)
                let isCurrent = step == current
                Button {
                    withAnimation(theme.motion.quick) { current = step }
                } label: {
                    HStack(spacing: theme.space.s10) {
                        ZStack {
                            Circle()
                                .fill(isCurrent ? theme.surface.selected : theme.surface.hover)
                                .overlay(Circle().strokeBorder(isCurrent ? theme.selectionBorder : .clear, lineWidth: theme.selectionStroke))
                                .frame(width: 26, height: 26)
                            if status == .done {
                                Image(systemName: "checkmark")
                                    .glyphSize(.footnote, weight: .bold)
                                    .foregroundColor(theme.status.success.foreground)
                            } else {
                                Text("\(index + 1)")
                                    .font(SettingsFont.smallLabel)
                                    .foregroundColor(isCurrent ? theme.text.link : theme.text.secondary)
                            }
                        }
                        VStack(alignment: .leading, spacing: theme.space.s2) {
                            Text(title(step))
                                .font(SettingsFont.compactLabel)
                                .foregroundColor(isCurrent ? theme.text.primary : theme.text.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            switch status {
                            case .done:
                                Text("Done", bundle: .module).font(SettingsFont.footnote).foregroundColor(
                                    theme.status.success.foreground
                                )
                            case .required:
                                Text("Required", bundle: .module).font(SettingsFont.footnote).foregroundColor(
                                    theme.status.warning.foreground
                                )
                            case .optional:
                                Text("Optional", bundle: .module).font(SettingsFont.footnote).foregroundColor(
                                    theme.text.tertiary
                                )
                            case .none:
                                EmptyView()
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, theme.space.s8)
                    .padding(.vertical, theme.space.s8)
                    .settingsChrome(isCurrent ? .selected : nil)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .settingsSearchHighlight(glowing == step)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Shared step pieces

struct StepDoneBanner: View {
    @Environment(\.theme) private var theme
    let text: String
    var body: some View {
        HStack(spacing: theme.space.s8) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(theme.status.success.foreground)
            Text(text).font(SettingsFont.compactLabel).foregroundColor(theme.text.primary)
        }
        .padding(theme.space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .settingsChrome(.status(.success))
    }
}

struct StepIssueList: View {
    @Environment(\.theme) private var theme
    let items: [SetupItem]
    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: theme.space.s8) {
                    Image(systemName: item.isBlocking ? "exclamationmark.circle.fill" : "info.circle")
                        .foregroundColor(
                            item.isBlocking ? theme.status.warning.foreground : theme.status.info.foreground
                        )
                        .padding(.top, theme.space.s2)
                    Text(item.detail)
                        .font(SettingsFont.caption)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// The inline accent button the agent detail view uses for actions like
/// "Choose…" next to the working folder, so wizard steps read as part of the
/// same product rather than a second button vocabulary.
struct StepActionButton: View {
    @Environment(\.theme) private var theme
    let title: LocalizedStringKey
    let icon: String
    var primary: Bool = true
    var isLoading: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: theme.space.s6) {
                if isLoading {
                    SettingsSpinner()
                } else {
                    Image(systemName: icon)
                        .glyphSize(.footnote, weight: .semibold)
                }
                Text(title, bundle: .module)
                    .font(SettingsFont.compactLabel)
                    .lineLimit(1)
            }
            .foregroundColor(primary ? theme.text.link : theme.text.secondary)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, theme.space.s12)
            .padding(.vertical, theme.space.s8)
            .settingsChrome(primary ? .selected : .subtle)
        }
        .buttonStyle(.plain)
    }
}

/// Thin rule with a word in the middle, for "one thing or the other" rows.
struct OrSeparator: View {
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: theme.space.s10) {
            ThemeHairlineDivider()
            Text("or", bundle: .module)
                .font(SettingsFont.smallLabel)
                .foregroundColor(theme.text.tertiary)
            ThemeHairlineDivider()
        }
    }
}

// MARK: - Permissions

struct PermissionsStep: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var permissionService = SystemPermissionService.shared
    let items: [SetupItem]
    let doneText: String
    let onChanged: () -> Void

    private var permissions: [SystemPermission] {
        items.compactMap { SystemPermission(rawValue: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s14) {
            if items.isEmpty {
                StepDoneBanner(text: doneText)
            } else {
                StepIssueList(items: items)
                ForEach(permissions, id: \.self) { permission in
                    HStack(spacing: theme.space.s10) {
                        Image(systemName: permission.iconName)
                            .foregroundColor(theme.text.secondary)
                            .frame(width: 18)
                        Text(permission.displayName)
                            .font(SettingsFont.compactLabel)
                            .foregroundColor(theme.text.primary)
                        Spacer()
                        StepActionButton(title: "Open System Settings", icon: "gear") {
                            permissionService.openSystemSettings(for: permission)
                        }
                    }
                    .padding(theme.space.s8)
                    .settingsChrome(.inset)
                }
                Text("Grant the permission, then come back to this window. It re-checks on its own.", bundle: .module)
                    .font(SettingsFont.rowDescription)
                    .foregroundColor(theme.text.tertiary)
            }
            StepActionButton(title: "Check Again", icon: "arrow.clockwise", primary: false) {
                permissionService.refreshAllPermissions()
                onChanged()
            }
        }
    }
}

