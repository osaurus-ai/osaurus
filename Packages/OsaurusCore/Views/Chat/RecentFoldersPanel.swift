//
//  RecentFoldersPanel.swift
//  osaurus
//
//  Hover-opened list of recently attached working folders for the chat
//  composer. It rides on the existing folder entry points (the + attach
//  button and the active folder chip) as a hover affordance only: clicking
//  those keeps its usual behavior, so nothing in the normal chat flow moves.
//

import SwiftUI

// MARK: - Hover popover

/// Rest time before a hover panel opens, and grace period after the pointer
/// leaves the anchor (long enough to cross into the popover) before it closes.
private let hoverPopoverShowDelay: UInt64 = 350_000_000
private let hoverPopoverHideDelay: UInt64 = 250_000_000

/// Present a popover while the pointer rests on the anchor or inside the
/// popover itself. A plain `.onHover { show = $0 }` dismisses the moment the
/// pointer leaves the anchor to enter the popover, so both sides debounce
/// through one shared hide timer. `enabled` lets the anchor suppress the
/// hover panel while it has its own click popover open.
struct HoverPopover<PopoverContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    var enabled: Bool = true
    var arrowEdge: Edge = .top
    /// Whether there is anything to show. Checked at open time so an empty
    /// list never presents a blank panel.
    var hasContent: () -> Bool = { true }
    @ViewBuilder let popoverContent: () -> PopoverContent

    @State private var showTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering { scheduleShow() } else { scheduleHide() }
            }
            .onChange(of: enabled) { _, isEnabled in
                if !isEnabled { dismissNow() }
            }
            .popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
                popoverContent()
                    .onHover { inside in
                        if inside { cancelHide() } else { scheduleHide() }
                    }
            }
    }

    private func scheduleShow() {
        cancelHide()
        guard enabled, !isPresented, showTask == nil else { return }
        showTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: hoverPopoverShowDelay)
            guard !Task.isCancelled else { return }
            showTask = nil
            guard enabled, hasContent() else { return }
            isPresented = true
        }
    }

    private func scheduleHide() {
        showTask?.cancel()
        showTask = nil
        guard isPresented, hideTask == nil else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: hoverPopoverHideDelay)
            guard !Task.isCancelled else { return }
            hideTask = nil
            isPresented = false
        }
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func dismissNow() {
        showTask?.cancel()
        showTask = nil
        cancelHide()
        isPresented = false
    }
}

extension View {
    /// See `HoverPopover`.
    func hoverPopover<PopoverContent: View>(
        isPresented: Binding<Bool>,
        enabled: Bool = true,
        arrowEdge: Edge = .top,
        hasContent: @escaping () -> Bool = { true },
        @ViewBuilder content: @escaping () -> PopoverContent
    ) -> some View {
        modifier(
            HoverPopover(
                isPresented: isPresented,
                enabled: enabled,
                arrowEdge: arrowEdge,
                hasContent: hasContent,
                popoverContent: content
            )
        )
    }
}

// MARK: - Panel

/// The recent-folders list itself. Rows show the folder name with the full
/// path as a tooltip, a remove affordance on hover, and a trailing
/// "Choose Folder…" row that opens the regular open panel.
struct RecentFoldersPanel: View {
    @ObservedObject private var store = RecentFoldersStore.shared
    @Environment(\.theme) private var theme

    /// Path of the folder currently attached to the chat, if any. Shown with
    /// a check so the hover list reads as "where can I switch to".
    var activePath: String? = nil
    let onPick: (RecentFoldersStore.Entry) -> Void
    let onChoose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent Folders", bundle: .module)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 4)

            ForEach(store.entries) { entry in
                RecentFolderRow(
                    entry: entry,
                    isActive: entry.path == activePath,
                    onPick: { onPick(entry) },
                    onRemove: { store.remove(path: entry.path) }
                )
            }

            Divider()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)

            ChooseFolderRow(action: onChoose)
        }
        .padding(.vertical, 6)
        .frame(width: 240)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
        .onAppear { store.pruneMissing() }
    }

    private struct RecentFolderRow: View {
        let entry: RecentFoldersStore.Entry
        let isActive: Bool
        let onPick: () -> Void
        let onRemove: () -> Void
        @Environment(\.theme) private var theme
        @State private var isHovering = false

        var body: some View {
            Button(action: onPick) {
                HStack(spacing: 10) {
                    Image(systemName: isActive ? "checkmark" : "folder")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                        .foregroundColor(isActive ? theme.accentColor : theme.secondaryText)
                    Text(verbatim: entry.name)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                // Leave room for the remove button so it never overlaps the name.
                .padding(.trailing, 18)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? theme.secondaryBackground.opacity(0.8) : Color.clear)
                )
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.path)
            .accessibilityLabel(Text(verbatim: entry.name))
            .accessibilityValue(Text(verbatim: entry.path))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
            .overlay(alignment: .trailing) {
                if isHovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(theme.tertiaryText)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(theme.secondaryBackground.opacity(0.9)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14)
                    .localizedHelp("Remove from recent folders")
                    .accessibilityLabel(Text("Remove from recent folders", bundle: .module))
                }
            }
        }
    }

    private struct ChooseFolderRow: View {
        let action: () -> Void
        @Environment(\.theme) private var theme
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                        .foregroundColor(theme.secondaryText)
                    Text("Choose Folder…", bundle: .module)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isHovering ? theme.secondaryBackground.opacity(0.8) : Color.clear)
                )
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
        }
    }
}
