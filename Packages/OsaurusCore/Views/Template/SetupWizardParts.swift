//
//  SetupWizardParts.swift
//  osaurus
//
//  Shared setup wizard pieces: the step rail, done and issue banners,
//  inline action buttons, and the permissions step. Each wizard owns its
//  own steps and what they edit.
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
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                let status = state(step)
                let isCurrent = step == current
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { current = step }
                } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(isCurrent ? theme.accentColor.opacity(0.15) : theme.tertiaryBackground)
                                .frame(width: 26, height: 26)
                            if status == .done {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(theme.successColor)
                            } else {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(isCurrent ? theme.accentColor : theme.secondaryText)
                            }
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(title(step))
                                .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                                .foregroundColor(isCurrent ? theme.primaryText : theme.secondaryText)
                            switch status {
                            case .done:
                                Text("Done", bundle: .module).font(.system(size: 10)).foregroundColor(theme.successColor)
                            case .required:
                                Text("Required", bundle: .module).font(.system(size: 10)).foregroundColor(theme.warningColor)
                            case .optional:
                                Text("Optional", bundle: .module).font(.system(size: 10)).foregroundColor(theme.tertiaryText)
                            case .none:
                                EmptyView()
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isCurrent ? theme.accentColor.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .settingsSearchHighlight(glowing == step)
            }
            Spacer()
        }
        .padding(12)
        .background(theme.secondaryBackground.opacity(0.5))
    }
}

// MARK: - Shared step pieces

struct StepDoneBanner: View {
    @Environment(\.theme) private var theme
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(theme.successColor)
            Text(text).font(.system(size: 12, weight: .medium)).foregroundColor(theme.primaryText)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.successColor.opacity(0.08)))
    }
}

struct StepIssueList: View {
    @Environment(\.theme) private var theme
    let items: [SetupItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.isBlocking ? "exclamationmark.circle.fill" : "info.circle")
                        .foregroundColor(item.isBlocking ? theme.warningColor : theme.infoColor)
                        .padding(.top, 1)
                    Text(item.detail)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(title, bundle: .module)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(primary ? theme.accentColor : theme.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(primary ? theme.accentColor.opacity(0.08) : theme.tertiaryBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(primary ? theme.accentColor.opacity(0.2) : theme.inputBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

/// Thin rule with a word in the middle, for "one thing or the other" rows.
struct OrSeparator: View {
    @Environment(\.theme) private var theme
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(theme.inputBorder).frame(height: 1)
            Text("or", bundle: .module)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.tertiaryText)
            Rectangle().fill(theme.inputBorder).frame(height: 1)
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
        VStack(alignment: .leading, spacing: 14) {
            if items.isEmpty {
                StepDoneBanner(text: doneText)
            } else {
                StepIssueList(items: items)
                ForEach(permissions, id: \.self) { permission in
                    HStack(spacing: 10) {
                        Image(systemName: permission.iconName)
                            .foregroundColor(theme.secondaryText)
                            .frame(width: 18)
                        Text(permission.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.primaryText)
                        Spacer()
                        StepActionButton(title: "Open System Settings", icon: "gear") {
                            permissionService.openSystemSettings(for: permission)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(theme.tertiaryBackground.opacity(0.6)))
                }
                Text("Grant the permission, then come back to this window. It re-checks on its own.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
            }
            StepActionButton(title: "Check Again", icon: "arrow.clockwise", primary: false) {
                permissionService.refreshAllPermissions()
                onChanged()
            }
        }
    }
}

