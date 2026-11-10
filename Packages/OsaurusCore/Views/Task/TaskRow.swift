//
//  TaskRow.swift
//  osaurus
//
//  One task as a minimal card: title, what it runs, one status line and,
//  while it runs, Stop. Shared by the Tasks tab and `RecentTasksList`.
//

import SwiftUI

/// Words and tones for a task, shared by rows and the detail sheet.
@MainActor
enum TaskPresentation {
    static func icon(_ task: OsaurusTask) -> String {
        switch task.work {
        case .agentTurn: "person.crop.circle"
        case .workflowRun: "flowchart"
        case .subagent: "person.2.wave.2"
        }
    }

    static func tone(_ task: OsaurusTask, now: Date = Date()) -> StatusChip.Tone {
        if task.isStale(at: now) { return .warning }
        switch task.state {
        case .running, .admitted: return .info
        case .waitingUser: return .warning
        case .succeeded: return .success
        case .failed: return .error
        case .received, .queued, .cancelled, .interrupted, .suppressed, .filtered, .duplicate: return .neutral
        }
    }

    static func stateLabel(_ task: OsaurusTask, now: Date = Date()) -> String {
        task.isStale(at: now) ? L("Stale") : task.state.displayName
    }

    /// Why a waiting task is not running, only when it waits on something
    /// other than a free slot.
    static func waitLabel(_ reason: String?) -> String? {
        switch reason {
        case "foreground_active": L("Waiting for the chat to finish")
        case "paused": L("Queue paused")
        case "queue_full": L("Queue full")
        default: nil
        }
    }

    /// One line under the title.
    static func statusLine(_ task: OsaurusTask, now: Date = Date()) -> String {
        var parts: [String] = [task.origin.displayName]
        switch task.state {
        case .running, .admitted:
            if let started = task.startedAt { parts.append(duration(now.timeIntervalSince(started))) }
            if task.isStale(at: now) {
                parts.append(L("No progress for over a minute"))
            } else if let note = task.progressNote, !note.isEmpty {
                parts.append(note)
            }
        case .queued, .received:
            if let wait = waitLabel(task.waitReason) { parts.append(wait) }
        case .waitingUser:
            parts.append(L("Waiting for your answer"))
        case .failed:
            parts.append(task.lastError ?? task.reason ?? L("Failed"))
        case .succeeded, .cancelled, .interrupted, .suppressed, .filtered, .duplicate:
            if let finished = task.finishedAt {
                parts.append(finished.formatted(.relative(presentation: .named)))
            }
            if let started = task.startedAt, let finished = task.finishedAt {
                parts.append(L("took \(duration(finished.timeIntervalSince(started)))"))
            }
            if task.state == .suppressed, let reason = task.reason { parts.append(reason) }
        }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : seconds >= 60 ? [.minute, .second] : [.second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: max(0, seconds)) ?? ""
    }
}

struct TaskRow: View {
    let row: OsaurusTask
    let onOpen: () -> Void

    init(task: OsaurusTask, onOpen: @escaping () -> Void) {
        self.row = task
        self.onOpen = onOpen
    }

    /// The live record while the task runs, so its lease and state read
    /// current between list reloads.
    private var task: OsaurusTask { TaskStore.shared.live[row.id] ?? row }

    var body: some View {
        if task.state == .running || task.state == .admitted {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(now: context.date)
            }
        } else {
            content(now: Date())
        }
    }

    private func content(now: Date) -> some View {
        LibraryRow(
            title: task.title,
            subtitle: TaskPresentation.statusLine(task, now: now),
            action: onOpen,
            leading: { SettingsIconTile(icon: TaskPresentation.icon(task), size: 28) },
            badges: {
                StatusChip(TaskPresentation.stateLabel(task, now: now), tone: TaskPresentation.tone(task, now: now))
            },
            trailing: {
                if TaskControl.canStop(task) {
                    SettingsButton(.secondary, "Stop", icon: "stop.fill", size: .compact) {
                        TaskControl.stop(task)
                    }
                }
            }
        )
    }
}

/// One live foreground reservation: who holds a model, which one, where it
/// runs and for how long. A chat row opens its conversation.
struct ForegroundRow: View {
    @Environment(\.theme) private var theme
    let reservation: ForegroundReservation
    let modelName: String?

    var body: some View {
        SettingsRow(title: title, verbatimTitle: true) {
            Text(verbatim: detail)
        } trailing: {
            HStack(spacing: theme.space.s8) {
                Text(timerInterval: reservation.startedAt ... Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .font(SettingsFont.rowDescription)
                    .foregroundStyle(theme.text.tertiary)
                if let chat = openableChat {
                    SettingsButton(.tertiary, "Open", size: .compact) {
                        TaskControl.openChat(chat, agentId: nil)
                    }
                }
            }
        }
    }

    private var isPlugin: Bool { reservation.owner.hasPrefix("plugin:") }

    /// Chat reservations are owned by the session id (or the run id of a
    /// chat not yet saved, which has nothing to open).
    private var chatSession: ChatSessionData? {
        guard reservation.kind == .chat, let id = UUID(uuidString: reservation.owner) else { return nil }
        return ChatSessionsManager.shared.sessions.first { $0.id == id }
    }

    private var openableChat: UUID? {
        guard reservation.kind == .chat, let id = UUID(uuidString: reservation.owner) else { return nil }
        let open = ChatWindowManager.shared.findWindow(bySessionId: id) != nil
        return open || chatSession != nil ? id : nil
    }

    private var title: String {
        switch reservation.kind {
        case .chat:
            if let session = chatSession, !session.title.isEmpty { return session.title }
            return L("Chat")
        case .api:
            return isPlugin ? L("Plugin request") : L("API request")
        }
    }

    private var detail: String {
        var parts: [String] = []
        switch reservation.kind {
        case .chat: parts.append(L("Chat"))
        case .api:
            parts.append(isPlugin ? String(reservation.owner.dropFirst("plugin:".count)) : L("API"))
        }
        if let modelName, !modelName.isEmpty { parts.append(modelName) }
        parts.append(reservation.isLocal ? L("On this Mac") : L("Remote"))
        return parts.joined(separator: " · ")
    }
}

/// The newest tasks matching `query`, live ones included, each opening its
/// detail. Embedded on automation, agent and workflow pages.
struct RecentTasksList: View {
    let query: TaskQuery
    var emptyText: String = "Nothing has run yet."

    @State private var tasks: [OsaurusTask] = []
    @State private var detail: OsaurusTask?
    private var store: TaskStore { .shared }

    var body: some View {
        Group {
            if tasks.isEmpty {
                SettingsEmptyState(inline: "checklist", title: emptyText)
            } else {
                ForEach(tasks) { task in
                    TaskRow(task: task) { detail = task }
                }
            }
        }
        .task(id: store.revision) { await reload() }
        .onChange(of: query) { Task { await reload() } }
        .sheet(item: $detail) { task in
            TaskDetailSheet(taskId: task.id) { detail = nil }
        }
    }

    private func reload() async {
        tasks = await store.tasks(query)
    }
}
