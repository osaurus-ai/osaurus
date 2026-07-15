//
//  NotchNavigationRails.swift
//  osaurus
//
//  Focused navigation components for the expanded notch: agent tabs and
//  the selected agent's swipeable session carousel.
//

import SwiftUI

// MARK: - Agent Tab Rail

/// Horizontal, scrollable rail of agent tabs shown when more than one agent
/// has notch-visible sessions.
struct NotchAgentTabRail: View {
    let groups: [NotchAgentGroup]
    let selectedAgentId: UUID?
    let agentResolver: (UUID?) -> Agent
    let avatarBuilder: (Agent, CGFloat) -> AnyView
    let statusColor: (BackgroundTaskState?) -> Color
    let onSelect: (NotchAgentGroup) -> Void
    let onClose: (NotchAgentGroup) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(groups) { group in
                    tabChip(group)
                }
            }
            .padding(.vertical, 3)
        }
    }

    private func tabChip(_ group: NotchAgentGroup) -> some View {
        let isSelected = group.agentId == selectedAgentId
        let agent = agentResolver(group.agentId)
        return HStack(spacing: 8) {
            avatarBuilder(agent, 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.system(size: 11, weight: isSelected ? .bold : .semibold))
                    .foregroundColor(isSelected ? .white : Color.white.opacity(0.72))
                    .lineLimit(1)
                Text(
                    group.activeTaskCount > 0
                        ? "\(group.activeTaskCount) active"
                        : "\(group.tasks.count) recent"
                )
                .font(.system(size: 8.5, weight: .medium))
                .foregroundColor(Color.white.opacity(0.42))
                .lineLimit(1)
            }
            .frame(minWidth: 74, maxWidth: 110, alignment: .leading)

            if group.tasks.count > 1 {
                Text("\(group.tasks.count)")
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color.white.opacity(0.55))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }

            Circle()
                .fill(statusColor(group.primaryTask))
                .frame(width: 7, height: 7)
                .shadow(color: statusColor(group.primaryTask).opacity(0.5), radius: 3)

            Button(action: { onClose(group) }) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.45))
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Close agent tab", bundle: .module))
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.12 : 0.045))
        )
        .overlay(alignment: .bottom) {
            if isSelected {
                Capsule()
                    .fill(statusColor(group.primaryTask))
                    .frame(height: 2)
                    .padding(.horizontal, 12)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(isSelected ? 0.18 : 0.07), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture { onSelect(group) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(agent.name), \(group.tasks.count) session(s)"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Session Rail

/// Swipeable session carousel for the selected agent, with explicit previous
/// and next controls for pointer and keyboard navigation.
struct NotchSessionRail: View {
    let tasks: [BackgroundTaskState]
    let selectedTaskId: UUID?
    let statusColor: (BackgroundTaskState?) -> Color
    let onSelect: (BackgroundTaskState) -> Void
    let onRename: (BackgroundTaskState) -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("SESSIONS", bundle: .module)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .tracking(1.1)
                    .foregroundColor(Color.white.opacity(0.4))
                Spacer()
                if let index = selectedIndex {
                    Text("\(index + 1) / \(tasks.count)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color.white.opacity(0.38))
                }
            }

            HStack(spacing: 7) {
                navigationButton(
                    systemName: "chevron.left",
                    help: L("Previous session"),
                    shortcut: .leftArrow,
                    action: onPrevious
                )

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                                sessionCard(task, index: index)
                                    .id(task.id)
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .onChange(of: selectedTaskId) { _, id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.22)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }

                navigationButton(
                    systemName: "chevron.right",
                    help: L("Next session"),
                    shortcut: .rightArrow,
                    action: onNext
                )
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 38)
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height),
                        abs(value.translation.width) > 55
                    else { return }
                    value.translation.width < 0 ? onNext() : onPrevious()
                }
        )
    }

    private var selectedIndex: Int? {
        tasks.firstIndex { $0.id == selectedTaskId }
    }

    private func navigationButton(
        systemName: String,
        help: String,
        shortcut: KeyEquivalent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color.white.opacity(0.72))
                .frame(width: 28, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut, modifiers: .command)
        .help("\(help) (⌘\(systemName.contains("left") ? "←" : "→"))")
        .accessibilityLabel(Text(help))
    }

    private func sessionCard(_ task: BackgroundTaskState, index: Int) -> some View {
        let isSelected = task.id == selectedTaskId
        return Button(action: { onSelect(task) }) {
            HStack(spacing: 8) {
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? statusColor(task) : Color.white.opacity(0.3))

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.taskTitle)
                        .font(.system(size: 11, weight: isSelected ? .bold : .semibold))
                        .foregroundColor(isSelected ? .white : Color.white.opacity(0.66))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor(task))
                            .frame(width: 5, height: 5)
                        Text(task.status.displayName)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundColor(Color.white.opacity(0.42))
                    }
                }
                .frame(width: 128, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(
                        isSelected
                            ? statusColor(task).opacity(0.13)
                            : Color.white.opacity(0.035)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(
                        isSelected ? statusColor(task).opacity(0.45) : Color.white.opacity(0.07),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .shadow(color: isSelected ? statusColor(task).opacity(0.12) : .clear, radius: 7)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onRename(task)
            } label: {
                Label(L("Rename…"), systemImage: "pencil")
            }
        }
        .accessibilityLabel(Text("\(task.taskTitle), \(task.status.displayName)"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
