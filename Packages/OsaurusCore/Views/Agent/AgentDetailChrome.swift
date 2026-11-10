//
//  AgentDetailChrome.swift
//  osaurus
//
//  Shared chrome for the agent and workspace *detail* surfaces:
//  `AgentHeaderAvatar` fills `SettingsPageHeader(leading:)`,
//  `AgentDetailIdentityLabel` is the avatar + name block for rows, and
//  `AgentSwitcherPopover` jumps between agents.
//
//  Sheet-specific chrome (headers, footers, button styles, text fields) lives
//  in `DesignSystem/SettingsSheet.swift`; this file is for the persistent detail panes.
//

import SwiftUI

// MARK: - Detail Header Avatar

/// The `leading:` avatar of an agent, remote agent or workspace detail
/// header. With `onSwitch`, it's a button with a chevron that opens a
/// switcher.
struct AgentHeaderAvatar: View {
    @Environment(\.theme) private var theme

    let mascotId: String?
    let name: String
    let tint: Color
    var customImageURL: URL? = nil
    var showsRemoteGlyph: Bool = false
    var switchHelp: String = "Switch agent"
    var onSwitch: (() -> Void)? = nil

    var body: some View {
        if let onSwitch {
            Button(action: onSwitch) {
                HStack(spacing: theme.space.s4) {
                    avatar
                    Image(systemName: "chevron.down")
                        .glyphSize(8, weight: .semibold)
                        .foregroundColor(theme.text.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .settingsHelp(switchHelp)
            .settingsAccessibilityLabel(switchHelp)
        } else {
            avatar
        }
    }

    private var avatar: some View {
        AgentAvatarView(
            mascotId: mascotId,
            name: name,
            tint: tint,
            diameter: 32,
            customImageURL: customImageURL,
            monogramFontSize: 14,
            borderWidth: 1.5
        )
        .overlay(alignment: .bottomTrailing) {
            if showsRemoteGlyph {
                RemoteAvatarBadge(glyphSize: 8, padding: 3)
                    .offset(x: 2, y: 2)
            }
        }
        .animation(theme.motion.springAnimation, value: name)
        .animation(theme.motion.springAnimation, value: mascotId)
    }
}

/// Small "this is a remote agent" antenna badge, designed to overlay the
/// bottom-trailing corner of an avatar. Matches the decoration on the remote
/// grid card so remote agents read the same way everywhere (header, switcher
/// rows, grid). The ring blends the badge into whatever surface hosts it.
struct RemoteAvatarBadge: View {
    @Environment(\.theme) private var theme

    var glyphSize: CGFloat = 8
    var padding: CGFloat = 3
    /// Color of the 1.5pt ring around the badge — pass the host surface color
    /// (card vs. header background) so the badge reads as floating above it.
    var ringColor: Color? = nil

    var body: some View {
        Image(systemName: "antenna.radiowaves.left.and.right")
            .glyphSize(glyphSize, weight: .bold)
            .foregroundColor(theme.action.primary.default.foreground)
            .padding(padding)
            .background(Circle().fill(theme.action.primary.default.background))
            .overlay(Circle().strokeBorder(ringColor ?? theme.surface.raised, lineWidth: theme.stroke.default))
    }
}

/// Avatar + name (+ optional subtitle + optional switcher chevron) block used
/// inside the header's identity slot. Local wraps it in the agent-switcher
/// button; remote does too, and sets `showsRemoteGlyph` so the avatar carries
/// the antenna decoration instead of a free-floating "Remote" pill.
struct AgentDetailIdentityLabel: View {
    @Environment(\.theme) private var theme

    let mascotId: String?
    let name: String
    let tint: Color
    var subtitle: String? = nil
    var showsChevron: Bool = false
    var customImageURL: URL? = nil
    var diameter: CGFloat = 28
    var monogramFontSize: CGFloat = 13
    var maxWidth: CGFloat? = 260
    /// Overlays the small antenna badge on the avatar to mark a remote agent.
    var showsRemoteGlyph: Bool = false
    /// Surface color the avatar sits on, used for the remote badge ring so it
    /// blends with the header (`secondaryBackground`) vs. a card row.
    var glyphRingColor: Color? = nil

    var body: some View {
        HStack(spacing: 10) {
            AgentAvatarView(
                mascotId: mascotId,
                name: name,
                tint: tint,
                diameter: diameter,
                customImageURL: customImageURL,
                monogramFontSize: monogramFontSize,
                borderWidth: 1.5
            )
            .overlay(alignment: .bottomTrailing) {
                if showsRemoteGlyph {
                    RemoteAvatarBadge(
                        glyphSize: max(6, diameter * 0.26),
                        padding: max(2, diameter * 0.085),
                        ringColor: glyphRingColor
                    )
                    .offset(x: 2, y: 2)
                }
            }
            .animation(theme.motion.springAnimation, value: name)
            .animation(theme.motion.springAnimation, value: mascotId)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name.isEmpty ? L("Untitled Agent") : name)
                        .font(SettingsFont.sectionTitle)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if showsChevron {
                        Image(systemName: "chevron.down")
                            .glyphSize(8, weight: .semibold)
                            .foregroundColor(theme.text.tertiary)
                    }
                }
                if let subtitle,
                    !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    Text(subtitle)
                        .font(SettingsFont.rowDescription)
                        .foregroundColor(theme.text.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
        }
    }
}

// MARK: - Agent Switcher Popover

/// Shared "Switch Agent" popover surfaced from the identity block of BOTH
/// detail headers. Lists every local (non-built-in) agent and every paired
/// remote agent so the user can jump between them without going back to the
/// grid. The host header owns the `isPresented` binding and performs the
/// actual navigation; this view only renders rows and reports taps.
struct AgentSwitcherPopover: View {
    @Environment(\.theme) private var theme

    let localAgents: [Agent]
    let remoteAgents: [RemoteAgent]
    /// Marked with a checkmark when the popover is shown from that agent's own
    /// detail view. At most one of these is non-nil in practice.
    let currentLocalAgentId: UUID?
    let currentRemoteAgentId: UUID?
    let onSelectLocal: (Agent) -> Void
    let onSelectRemote: (RemoteAgent) -> Void
    let onDismiss: () -> Void

    private var totalCount: Int { localAgents.count + remoteAgents.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().opacity(0.5)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(localAgents, id: \.id) { agent in
                        row(
                            mascotId: agent.avatar,
                            name: agent.name,
                            subtitle: agent.displayDescription,
                            customImageURL: agent.customAvatarURL,
                            isRemote: false,
                            isCurrent: agent.id == currentLocalAgentId,
                            select: { onSelectLocal(agent) }
                        )
                    }

                    if !remoteAgents.isEmpty {
                        // Only label the remote group when local agents are
                        // also present — otherwise the single list speaks for
                        // itself and the header already says "Switch Agent".
                        if !localAgents.isEmpty {
                            sectionLabel("Remote")
                        }
                        ForEach(remoteAgents, id: \.id) { agent in
                            row(
                                mascotId: agent.avatar,
                                name: agent.name,
                                subtitle: agent.description,
                                customImageURL: nil,
                                isRemote: true,
                                isCurrent: agent.id == currentRemoteAgentId,
                                select: { onSelectRemote(agent) }
                            )
                        }
                    }
                }
                .padding(.vertical, theme.space.s6)
                .padding(.horizontal, theme.space.s6)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 280)
        .background(theme.surface.raised)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .glyphSize(10, weight: .semibold)
                .foregroundColor(theme.text.tertiary)
            Text("Switch Agent", bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.tertiary)
            Spacer()
            CountBadge(totalCount)
        }
        .padding(.horizontal, theme.space.s12)
        .padding(.top, theme.space.s12)
        .padding(.bottom, theme.space.s8)
    }

    private func sectionLabel(_ key: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .glyphSize(8, weight: .bold)
            Text(key, bundle: .module)
                .font(SettingsFont.compactLabel)
        }
        .foregroundColor(theme.text.tertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, theme.space.s8)
        .padding(.top, theme.space.s8)
        .padding(.bottom, theme.space.s2)
    }

    /// A single switcher row — avatar (with the antenna badge for remote
    /// agents) + name + optional subtitle, highlighted with a checkmark when
    /// it's the agent the popover was opened from. Tapping the current row just
    /// dismisses; any other row fires `select`.
    private func row(
        mascotId: String?,
        name: String,
        subtitle: String,
        customImageURL: URL?,
        isRemote: Bool,
        isCurrent: Bool,
        select: @escaping () -> Void
    ) -> some View {
        Button {
            if isCurrent { onDismiss() } else { select() }
        } label: {
            HStack(spacing: 10) {
                AgentAvatarView(
                    mascotId: mascotId,
                    name: name,
                    tint: agentColorFor(name),
                    diameter: 26,
                    customImageURL: customImageURL,
                    monogramFontSize: 11,
                    borderWidth: 1.5
                )
                .overlay(alignment: .bottomTrailing) {
                    if isRemote {
                        RemoteAvatarBadge(glyphSize: 6, padding: 2)
                            .offset(x: 2, y: 2)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(name.isEmpty ? L("Untitled Agent") : name)
                        .font(SettingsFont.compactLabel)
                        .foregroundColor(theme.text.primary)
                        .lineLimit(1)
                    if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(subtitle)
                            .font(SettingsFont.footnote)
                            .foregroundColor(theme.text.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 4)

                if isCurrent {
                    Image(systemName: "checkmark")
                        .glyphSize(10, weight: .bold)
                        .foregroundColor(theme.text.link)
                }
            }
            .padding(.horizontal, theme.space.s8)
            .padding(.vertical, theme.space.s6)
            .settingsChrome(isCurrent ? .selected : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
