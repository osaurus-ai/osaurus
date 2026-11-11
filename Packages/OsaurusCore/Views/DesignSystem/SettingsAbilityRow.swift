//
//  SettingsAbilityRow.swift
//  osaurus
//
//  `SettingsAbilityRow` is the one row for an on/off capability (agent
//  abilities, per-agent workflows). It sits inside a grouped
//  `SettingsSection`, one row per ability.
//

import SwiftUI

/// Icon tile, title and description, a trailing switch, and the ability's
/// status underneath: a paused chip when a dependency suppresses it, any
/// accessory content (pickers, disclaimers), and a configure link while on.
struct SettingsAbilityRow<Accessory: View>: View {
    @Environment(\.theme) private var theme
    let title: String
    var description: String
    var icon: String?
    /// Switch binding; nil renders no switch (state is not a toggle, e.g. a
    /// folder grant) and `isActive` drives the tile.
    var isOn: Binding<Bool>?
    var isActive: Bool?
    /// False renders the row in `text.disabled` and disables the switch; the
    /// paused chip and accessory stay live so the cause can be reached.
    var isInteractive: Bool
    /// Already-localized warning shown when a dependency gates the ability off.
    var pausedNote: String?
    /// Makes the paused chip a "take me to the cause" button.
    var onPausedNoteTap: (() -> Void)?
    var configureLabel: String?
    var onConfigure: (() -> Void)?
    /// Title and description are user data (workflow names).
    var verbatim: Bool
    @ViewBuilder let accessory: Accessory

    /// `accessory` has no default so an unlabeled trailing closure always
    /// binds to it rather than to `onPausedNoteTap` / `onConfigure`.
    init(
        title: String,
        description: String = "",
        icon: String? = nil,
        isOn: Binding<Bool>? = nil,
        isActive: Bool? = nil,
        isInteractive: Bool = true,
        pausedNote: String? = nil,
        onPausedNoteTap: (() -> Void)? = nil,
        configureLabel: String? = nil,
        onConfigure: (() -> Void)? = nil,
        verbatim: Bool = false,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.description = description
        self.icon = icon
        self.isOn = isOn
        self.isActive = isActive
        self.isInteractive = isInteractive
        self.pausedNote = pausedNote
        self.onPausedNoteTap = onPausedNoteTap
        self.configureLabel = configureLabel
        self.onConfigure = onConfigure
        self.verbatim = verbatim
        self.accessory = accessory()
    }

    private static var tileSize: CGFloat { 26 }

    private var active: Bool {
        isOn?.wrappedValue ?? isActive ?? false
    }

    private var hasAccessory: Bool { Accessory.self != EmptyView.self }
    private var showsConfigure: Bool { active && configureLabel != nil && onConfigure != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            SettingsRow(
                title: title,
                description: description,
                verbatimTitle: verbatim,
                verbatimDescription: verbatim,
                leading: {
                    if let icon {
                        SettingsIconTile(
                            icon: icon,
                            size: Self.tileSize,
                            tint: !isInteractive ? theme.text.disabled : (active ? nil : theme.text.tertiary)
                        )
                    }
                }
            ) {
                if let isOn {
                    Toggle("", isOn: isOn)
                        .settingsSwitch()
                        .accessibilityLabel(
                            verbatim ? Text(verbatim: title) : Text(LocalizedStringKey(title), bundle: .module)
                        )
                }
            }
            .disabled(!isInteractive)

            if pausedNote != nil || hasAccessory || showsConfigure {
                VStack(alignment: .leading, spacing: theme.space.s8) {
                    pausedChip
                    accessory
                    configureLink
                }
                .padding(.leading, icon == nil ? 0 : Self.tileSize + theme.space.s12)
                .padding(.bottom, theme.space.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(theme.motion.springAnimation, value: active)
    }

    @ViewBuilder
    private var pausedChip: some View {
        if let pausedNote {
            let chip = StatusChip(pausedNote, tone: .warning, icon: "pause.circle.fill")
            Group {
                if let onPausedNoteTap {
                    Button(action: onPausedNoteTap) { chip.contentShape(Capsule()) }
                        .buttonStyle(.plain)
                        .pointingHandCursor()
                        .help(Text("Show the switch this depends on", bundle: .module))
                } else {
                    chip
                }
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    @ViewBuilder
    private var configureLink: some View {
        if showsConfigure, let configureLabel, let onConfigure {
            Button(action: onConfigure) {
                HStack(spacing: 4) {
                    Text(LocalizedStringKey(configureLabel), bundle: .module)
                    Image(systemName: "chevron.right")
                        .font(SettingsFont.glyphSmall)
                }
            }
            .assignedSettingsButtonStyle(.tertiary, size: .compact)
            .transition(.opacity)
        }
    }
}

extension SettingsAbilityRow where Accessory == EmptyView {
    /// Disfavored so a trailing-closure call resolves to the accessory init
    /// instead of binding the closure to `onPausedNoteTap` here.
    @_disfavoredOverload
    init(
        title: String,
        description: String = "",
        icon: String? = nil,
        isOn: Binding<Bool>? = nil,
        isActive: Bool? = nil,
        isInteractive: Bool = true,
        pausedNote: String? = nil,
        onPausedNoteTap: (() -> Void)? = nil,
        configureLabel: String? = nil,
        onConfigure: (() -> Void)? = nil,
        verbatim: Bool = false
    ) {
        self.init(
            title: title,
            description: description,
            icon: icon,
            isOn: isOn,
            isActive: isActive,
            isInteractive: isInteractive,
            pausedNote: pausedNote,
            onPausedNoteTap: onPausedNoteTap,
            configureLabel: configureLabel,
            onConfigure: onConfigure,
            verbatim: verbatim,
            accessory: { EmptyView() }
        )
    }
}
