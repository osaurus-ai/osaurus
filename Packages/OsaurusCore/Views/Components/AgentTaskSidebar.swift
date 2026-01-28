//
//  AgentTaskSidebar.swift
//  osaurus
//
//  Sidebar displaying the list of agent tasks for the current persona.
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

    var body: some View {
        VStack(spacing: 0) {
            // Header
            sidebarHeader

            Divider()
                .background(theme.tertiaryBackground)

            // Search
            SearchField(text: $searchQuery, placeholder: "Search tasks...")
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            // Task list
            if filteredTasks.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
        .background(theme.secondaryBackground.opacity(0.5))
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "bolt.circle.fill")
                    .foregroundColor(.orange)
                Text("Tasks")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }

            Spacer()

            // Task count
            Text("\(tasks.count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.tertiaryText)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(theme.tertiaryBackground)
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            if searchQuery.isEmpty {
                Image(systemName: "tray")
                    .font(.system(size: 28))
                    .foregroundColor(theme.tertiaryText)

                Text("No tasks yet")
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)

                Text("Enter a query to create your first task")
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .multilineTextAlignment(.center)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundColor(theme.tertiaryText)

                Text("No matching tasks")
                    .font(.system(size: 13))
                    .foregroundColor(theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Task List

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }

    // MARK: - Filtered Tasks

    private var filteredTasks: [AgentTask] {
        if searchQuery.isEmpty {
            return tasks
        }
        let query = searchQuery.lowercased()
        return tasks.filter { task in
            task.title.lowercased().contains(query) || task.query.lowercased().contains(query)
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
        HStack(spacing: 10) {
            // Status indicator
            statusIndicator
                .frame(width: 8, height: 8)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)

                Text(relativeDate(task.updatedAt))
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }

            Spacer()

            // Delete button (on hover)
            if isHovered {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
                .buttonStyle(.plain)
                .help("Delete task")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
        )
        .contentShape(Rectangle())
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

    @ViewBuilder
    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
    }

    private var statusColor: Color {
        switch task.status {
        case .active: return .orange
        case .completed: return .green
        case .cancelled: return .gray
        }
    }

    // MARK: - Background

    private var backgroundColor: Color {
        if isSelected {
            return theme.accentColor.opacity(0.15)
        } else if isHovered {
            return theme.tertiaryBackground.opacity(0.5)
        } else {
            return Color.clear
        }
    }

    // MARK: - Relative Date

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
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
