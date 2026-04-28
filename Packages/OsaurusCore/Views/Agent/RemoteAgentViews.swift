//
//  RemoteAgentViews.swift
//  osaurus
//
//  UI for agents that the user has paired into this device via the
//  `osaurus://...?pair=...` deeplink flow.
//
//  Two surfaces:
//    - `RemoteAgentCard`        — grid card that lives next to the local
//                                  `AgentCard` in `AgentsView.gridContent`,
//                                  with a "Remote" badge.
//    - `RemoteAgentDetailView`  — the read-only detail panel shown when the
//                                  user taps a remote card.
//

import SwiftUI

// MARK: - Remote Agent Card

struct RemoteAgentCard: View {
    @Environment(\.theme) private var theme

    let remote: RemoteAgent
    let animationDelay: Double
    let hasAppeared: Bool
    let onSelect: () -> Void
    let onChat: () -> Void
    let onRemove: () -> Void

    @State private var isHovered: Bool = false
    @State private var showRemoveConfirm: Bool = false

    private var color: Color { agentColorFor(remote.name) }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    avatar
                    metadata
                    Spacer(minLength: 8)
                    overflowMenu
                }

                if !remote.description.isEmpty {
                    Text(remote.description)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                stats
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .padding(16)
            .background(cardBackground)
            .overlay(hoverGradient)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(cardBorder)
            .scaleEffect(hasAppeared ? 1 : 0.95)
            .opacity(hasAppeared ? 1 : 0)
            .animation(.spring(response: 0.35, dampingFraction: 0.85).delay(animationDelay), value: hasAppeared)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovered = hovering }
        }
        .themedAlert(
            "Remove this remote agent?",
            isPresented: $showRemoveConfirm,
            message: "You'll lose access to \"\(remote.name)\" via this share link. You can be re-invited later.",
            primaryButton: .destructive("Remove") {
                onRemove()
            },
            secondaryButton: .cancel("Cancel")
        )
    }

    // MARK: Subviews

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.15), color.opacity(0.05)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Circle()
                .strokeBorder(color.opacity(0.4), lineWidth: 2)
            Text(remote.name.prefix(1).uppercased())
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(color)
            // Tiny "remote" decoration in the bottom-right of the avatar.
            // Reads at a glance even when the card is dense.
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)
                .padding(3)
                .background(Circle().fill(theme.accentColor))
                .overlay(Circle().strokeBorder(theme.cardBackground, lineWidth: 1.5))
                .offset(x: 12, y: 12)
        }
        .frame(width: 36, height: 36)
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(remote.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Text("Remote", bundle: .module)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(theme.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(theme.accentColor.opacity(0.12)))
            }
            Text(remote.shortAddress)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.tertiaryText)
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                onChat()
            } label: {
                Label {
                    Text("Chat", bundle: .module)
                } icon: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
            }
            Button(action: onSelect) {
                Label {
                    Text("Open Details", bundle: .module)
                } icon: {
                    Image(systemName: "info.circle")
                }
            }
            Divider()
            Button(role: .destructive) {
                showRemoveConfirm = true
            } label: {
                Label {
                    Text("Remove", bundle: .module)
                } icon: {
                    Image(systemName: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(theme.tertiaryBackground))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
    }

    private var stats: some View {
        HStack(spacing: 12) {
            statChip(icon: "calendar", text: "Paired \(remote.pairedAt.formatted(.relative(presentation: .named)))")
            if let used = remote.lastUsedAt {
                statChip(icon: "clock", text: "Used \(used.formatted(.relative(presentation: .named)))")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
        }
        .foregroundColor(theme.tertiaryText)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(theme.tertiaryBackground.opacity(0.5)))
    }

    private var cardBackground: some View {
        LinearGradient(
            colors: [
                isHovered ? theme.cardBackground : theme.cardBackground.opacity(0.95),
                theme.cardBackground.opacity(0.85),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var hoverGradient: some View {
        Group {
            if isHovered {
                LinearGradient(
                    colors: [theme.accentColor.opacity(0.06), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(
                isHovered ? theme.accentColor.opacity(0.35) : theme.cardBorder,
                lineWidth: 1
            )
    }
}

// MARK: - Remote Agent Detail View

struct RemoteAgentDetailView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var manager = RemoteAgentManager.shared

    let remoteId: UUID
    let onBack: () -> Void
    let onRemoved: () -> Void
    let onChat: (RemoteAgent) -> Void

    @State private var note: String = ""
    @State private var showRemoveConfirm: Bool = false

    private var remote: RemoteAgent? { manager.remoteAgent(for: remoteId) }
    private var color: Color { agentColorFor(remote?.name ?? "") }

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let remote {
                        identityCard(for: remote)
                        sourceCard(for: remote)
                        noteCard(for: remote)
                        actionCard(for: remote)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                .font(.system(size: 32))
                                .foregroundColor(theme.tertiaryText)
                            Text("This remote agent is no longer available.", bundle: .module)
                                .font(.system(size: 12))
                                .foregroundColor(theme.tertiaryText)
                            Button {
                                onBack()
                            } label: {
                                Text("Go back", bundle: .module)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 80)
                    }
                }
                .padding(24)
            }
            .background(theme.primaryBackground)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .onAppear {
            note = remote?.note ?? ""
        }
        .themedAlert(
            "Remove this remote agent?",
            isPresented: $showRemoveConfirm,
            message: "You'll lose access via this share link. You can be re-invited later.",
            primaryButton: .destructive("Remove") {
                _ = manager.remove(id: remoteId)
                onRemoved()
            },
            secondaryButton: .cancel("Cancel")
        )
    }

    // MARK: Subviews

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Agents", bundle: .module)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)

            Rectangle()
                .fill(theme.primaryBorder)
                .frame(width: 1, height: 16)
                .opacity(0.6)

            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text(remote?.name ?? "Remote Agent")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(
            theme.secondaryBackground
                .overlay(
                    Rectangle()
                        .fill(theme.primaryBorder)
                        .frame(height: 1),
                    alignment: .bottom
                )
        )
    }

    private func identityCard(for remote: RemoteAgent) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.2), color.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Circle().strokeBorder(color.opacity(0.5), lineWidth: 2)
                Text(remote.name.prefix(1).uppercased())
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(color)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(remote.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                if !remote.description.isEmpty {
                    Text(remote.description)
                        .font(.system(size: 12))
                        .foregroundColor(theme.secondaryText)
                        .lineLimit(2)
                }
                Text(remote.agentAddress)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()
            Text("Remote", bundle: .module)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(theme.accentColor.opacity(0.12)))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func sourceCard(for remote: RemoteAgent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Source")
            metadataRow(label: "Relay URL", value: remote.relayBaseURL, mono: true)
            metadataRow(
                label: "Paired",
                value: remote.pairedAt.formatted(date: .abbreviated, time: .shortened),
                mono: false
            )
            if let last = remote.lastUsedAt {
                metadataRow(
                    label: "Last Used",
                    value: last.formatted(date: .abbreviated, time: .shortened),
                    mono: false
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func noteCard(for remote: RemoteAgent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Your Note")

            TextField(
                text: $note,
                prompt: Text("e.g., Alice's research agent", bundle: .module),
                axis: .vertical
            ) {
                Text("Note", bundle: .module)
            }
            .lineLimit(3, reservesSpace: true)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1)
                    )
            )
            .onChange(of: note) { _, newValue in
                manager.updateNote(newValue, for: remote.id)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private func actionCard(for remote: RemoteAgent) -> some View {
        HStack(spacing: 10) {
            Button {
                onChat(remote)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 11))
                    Text("Chat with this Agent", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(theme.accentColor))
            }
            .buttonStyle(.plain)

            Spacer()

            Button {
                showRemoveConfirm = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                    Text("Remove", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(theme.errorColor)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(theme.errorColor.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(LocalizedStringKey(text), bundle: .module)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(theme.tertiaryText)
            .tracking(0.5)
    }

    private func metadataRow(label: String, value: String, mono: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(LocalizedStringKey(label), bundle: .module)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(mono ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .foregroundColor(theme.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
        }
    }
}
