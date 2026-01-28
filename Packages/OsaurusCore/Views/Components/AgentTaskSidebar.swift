//
//  AgentTaskSidebar.swift
//  osaurus
//
//  Sidebar displaying the list of agent tasks for the current persona.
//  Uses shared sidebar components for consistent styling.
//

import SwiftUI

struct AgentTaskSidebar: View {
    let tasks: [AgentTask]
    let currentTaskId: String?
    let onSelect: (AgentTask) -> Void
    let onDelete: (String) -> Void

    @Environment(\.theme) private var theme: ThemeProtocol
    @State private var searchQuery: String = ""
    @State private var hoveredTaskId: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        SidebarContainer {
            // Header
            sidebarHeader

            // Search field
            SidebarSearchField(
                text: $searchQuery,
                placeholder: "Search tasks...",
                isFocused: $isSearchFocused
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()
                .opacity(0.3)

            // Task list
            if tasks.isEmpty {
                emptyState
            } else if filteredTasks.isEmpty {
                SidebarNoResultsView(searchQuery: searchQuery) {
                    withAnimation(theme.animationQuick()) {
                        searchQuery = ""
                    }
                }
            } else {
                taskList
            }
        }
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack {
            Text("Tasks")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(theme.primaryText)

            Spacer()

            // Task count badge
            if !tasks.isEmpty {
                Text("\(tasks.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(theme.tertiaryBackground.opacity(0.6))
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bolt.circle")
                .font(.system(size: 28))
                .foregroundColor(theme.secondaryText.opacity(0.5))
            Text("No tasks yet")
                .font(.system(size: 12))
                .foregroundColor(theme.secondaryText.opacity(0.7))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Task List

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredTasks) { task in
                    TaskRow(
                        task: task,
                        isSelected: task.id == currentTaskId,
                        isHovered: task.id == hoveredTaskId,
                        onSelect: { onSelect(task) },
                        onDelete: { onDelete(task.id) }
                    )
                    .onHover { hovering in
                        hoveredTaskId = hovering ? task.id : nil
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Filtered Tasks

    private var filteredTasks: [AgentTask] {
        if searchQuery.isEmpty {
            return tasks
        }
        return tasks.filter { task in
            SearchService.matches(query: searchQuery, in: task.title)
                || SearchService.matches(query: searchQuery, in: task.query)
        }
    }
}

// MARK: - Task Row

private struct TaskRow: View {
    let task: AgentTask
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @Environment(\.theme) private var theme: ThemeProtocol

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            statusIndicator

            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Text(formatRelativeDate(task.updatedAt))
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText.opacity(0.85))
            }

            Spacer()

            // Delete button (on hover)
            if isHovered {
                SidebarRowActionButton(
                    icon: "trash",
                    help: "Delete",
                    action: onDelete
                )
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(SidebarRowBackground(isSelected: isSelected, isHovered: isHovered))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button("Delete", role: .destructive) {
                onDelete()
            }
        }
    }

    // MARK: - Status Indicator

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch task.status {
        case .active: return theme.accentColor
        case .completed: return .green
        case .cancelled: return theme.tertiaryText
        }
    }
}

// MARK: - Preview

#if DEBUG
    struct AgentTaskSidebar_Previews: PreviewProvider {
        static var previews: some View {
            AgentTaskSidebar(
                tasks: [
                    AgentTask(
                        title: "Implement user authentication",
                        query: "Add login and signup functionality",
                        status: .active
                    ),
                    AgentTask(
                        title: "Fix navigation bug",
                        query: "The back button doesn't work on the settings page",
                        status: .completed
                    ),
                ],
                currentTaskId: nil,
                onSelect: { _ in },
                onDelete: { _ in }
            )
            .frame(width: 240, height: 400)
        }
    }
#endif
