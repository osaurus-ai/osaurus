//
//  AgentAvatarPicker.swift
//  osaurus
//
//  A custom agent's avatar choices: the name's first letter, a dino, or an
//  uploaded image.
//
//  - `AgentAvatarChoices`     the tiles and image buttons, inline or in a popover
//  - `AgentAvatarEditButton`  the avatar itself, opening the choices
//

import SwiftUI

/// What the avatar tiles do. The agent page owns saving.
struct AgentAvatarActions {
    let upload: () -> Void
    let removeImage: () -> Void
    /// `nil` picks the first-letter monogram.
    let pick: (String?) -> Void
}

// MARK: - Choices

/// One row of built-in choices (the first letter, then the dinos) above the
/// image buttons. An uploaded image replaces every built-in choice, so none
/// of the tiles is selected while one is set.
struct AgentAvatarChoices: View {
    @Environment(\.theme) private var theme

    let name: String
    let tint: Color
    let mascotId: String?
    let customImageURL: URL?
    let actions: AgentAvatarActions
    var diameter: CGFloat = 36

    private var pickedMascot: AgentMascot? { mascotId.flatMap(AgentMascot.init(storedID:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            HStack(spacing: theme.space.s8) {
                AgentAvatarTile(
                    name: name, tint: tint, mascotId: nil,
                    diameter: diameter, isSelected: customImageURL == nil && pickedMascot == nil,
                    help: L("First letter of the name")
                ) { actions.pick(nil) }
                ForEach(AgentMascot.allCases) { mascot in
                    AgentAvatarTile(
                        name: name, tint: tint, mascotId: mascot.id,
                        diameter: diameter, isSelected: customImageURL == nil && pickedMascot == mascot,
                        help: L(String.LocalizationValue(mascot.displayName))
                    ) { actions.pick(mascot.id) }
                }
            }
            HStack(spacing: theme.space.s8) {
                SettingsButton(
                    .secondary,
                    customImageURL == nil ? "Upload Image…" : "Replace Image…",
                    icon: "photo",
                    size: .compact,
                    action: actions.upload
                )
                if customImageURL != nil {
                    SettingsButton(.tertiary, "Remove Image", size: .compact, action: actions.removeImage)
                }
            }
        }
    }
}

/// One avatar choice. Selected draws a ring that follows the avatar's shape.
private struct AgentAvatarTile: View {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let name: String
    let tint: Color
    let mascotId: String?
    let diameter: CGFloat
    let isSelected: Bool
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    private var ringShape: RoundedRectangle {
        let side = diameter + theme.space.s4
        let radius = AgentAvatarView.cornerRadius(side: side, theme: theme, enabled: isEnabled)
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            AgentAvatarView(
                mascotId: mascotId,
                name: name,
                tint: tint,
                diameter: diameter,
                monogramFontSize: diameter * 0.4,
                borderWidth: theme.stroke.default,
                followsLibrarySize: false
            )
            .padding(theme.space.s2)
            .overlay {
                ringShape.strokeBorder(
                    isSelected ? theme.action.primary.default.background : (isHovering ? theme.border.strong : Color.clear),
                    lineWidth: theme.stroke.focus
                )
            }
            .scaleEffect(isHovering && !isSelected && !reduceMotion ? 1.05 : 1)
            .contentShape(ringShape)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(theme.motion.quick) { isHovering = hovering }
        }
        .help(Text(verbatim: help))
        .accessibilityLabel(Text(verbatim: help))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Edit Button

/// The agent's avatar as a button: a pencil badge marks it as editable, and
/// clicking opens the avatar choices.
struct AgentAvatarEditButton: View {
    @Environment(\.theme) private var theme

    let name: String
    let tint: Color
    let mascotId: String?
    let customImageURL: URL?
    let actions: AgentAvatarActions
    var diameter: CGFloat = 48
    var anchorId: String? = nil

    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            AgentAvatarView(
                mascotId: mascotId,
                name: name,
                tint: tint,
                diameter: diameter,
                customImageURL: customImageURL,
                monogramFontSize: diameter * 0.42,
                borderWidth: theme.stroke.default,
                followsLibrarySize: false
            )
            .overlay(alignment: .bottomTrailing) { badge.offset(x: theme.space.s2, y: theme.space.s2) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            withAnimation(theme.motion.quick) { isHovering = hovering }
        }
        .settingsHelp("Change Avatar")
        .settingsAccessibilityLabel("Change Avatar")
        .settingsLandingAnchor(anchorId)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popover
        }
        .animation(theme.motion.springAnimation, value: mascotId)
        .animation(theme.motion.springAnimation, value: customImageURL)
    }

    private var badge: some View {
        let active = isHovering || isPresented
        return Image(systemName: "pencil")
            .glyphSize(.tiny, weight: .bold)
            .foregroundColor(active ? theme.action.primary.default.foreground : theme.text.secondary)
            .padding(theme.space.s4)
            .background(Circle().fill(active ? theme.action.primary.default.background : theme.surface.raised))
            .overlay(Circle().strokeBorder(theme.surface.canvas, lineWidth: theme.stroke.default))
            .accessibilityHidden(true)
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: theme.space.s12) {
            Text("Avatar", bundle: .module)
                .font(SettingsFont.compactLabel)
                .foregroundColor(theme.text.primary)
            AgentAvatarChoices(
                name: name,
                tint: tint,
                mascotId: mascotId,
                customImageURL: customImageURL,
                actions: AgentAvatarActions(
                    upload: {
                        isPresented = false
                        actions.upload()
                    },
                    removeImage: actions.removeImage,
                    pick: actions.pick
                )
            )
        }
        .padding(theme.space.s16)
        .background(theme.surface.raised)
        .environment(\.theme, theme)
    }
}
