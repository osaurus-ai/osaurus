//
//  IssueStore.swift
//  osaurus
//
//  Storage layer for Osaurus Agents issues, dependencies, events, and tasks.
//  Provides CRUD operations and specialized queries.
//

import Foundation
import SQLite3

/// Storage layer for agent issues and related data
public struct IssueStore {
    private init() {}

    // MARK: - Issue Operations

    /// Creates a new issue in the database
    @discardableResult
    public static func createIssue(_ issue: Issue) throws -> Issue {
        let sql = """
                INSERT INTO issues (id, task_id, title, description, context, status, priority, type, result, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: issue.id)
                AgentDatabase.bindText(stmt, index: 2, value: issue.taskId)
                AgentDatabase.bindText(stmt, index: 3, value: issue.title)
                AgentDatabase.bindText(stmt, index: 4, value: issue.description)
                AgentDatabase.bindText(stmt, index: 5, value: issue.context)
                AgentDatabase.bindText(stmt, index: 6, value: issue.status.rawValue)
                AgentDatabase.bindInt(stmt, index: 7, value: issue.priority.rawValue)
                AgentDatabase.bindText(stmt, index: 8, value: issue.type.rawValue)
                AgentDatabase.bindText(stmt, index: 9, value: issue.result)
                AgentDatabase.bindDate(stmt, index: 10, value: issue.createdAt)
                AgentDatabase.bindDate(stmt, index: 11, value: issue.updatedAt)
            }
        ) { stmt in
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE {
                throw AgentDatabaseError.failedToExecute("Failed to insert issue")
            }
        }

        return issue
    }

    /// Gets an issue by ID
    public static func getIssue(id: String) throws -> Issue? {
        let sql = "SELECT * FROM issues WHERE id = ?"
        var issue: Issue?

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: id)
            }
        ) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                issue = parseIssueRow(stmt)
            }
        }

        return issue
    }

    /// Updates an existing issue
    public static func updateIssue(_ issue: Issue) throws {
        let sql = """
                UPDATE issues
                SET title = ?, description = ?, context = ?, status = ?, priority = ?, type = ?, result = ?, updated_at = ?
                WHERE id = ?
            """

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: issue.title)
                AgentDatabase.bindText(stmt, index: 2, value: issue.description)
                AgentDatabase.bindText(stmt, index: 3, value: issue.context)
                AgentDatabase.bindText(stmt, index: 4, value: issue.status.rawValue)
                AgentDatabase.bindInt(stmt, index: 5, value: issue.priority.rawValue)
                AgentDatabase.bindText(stmt, index: 6, value: issue.type.rawValue)
                AgentDatabase.bindText(stmt, index: 7, value: issue.result)
                AgentDatabase.bindDate(stmt, index: 8, value: Date())
                AgentDatabase.bindText(stmt, index: 9, value: issue.id)
            }
        ) { stmt in
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE {
                throw AgentDatabaseError.failedToExecute("Failed to update issue")
            }
        }
    }

    /// Deletes an issue by ID
    public static func deleteIssue(id: String) throws {
        let sql = "DELETE FROM issues WHERE id = ?"

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: id)
            }
        ) { stmt in
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE {
                throw AgentDatabaseError.failedToExecute("Failed to delete issue")
            }
        }
    }

    /// Lists all issues, optionally filtered by status
    public static func listIssues(status: IssueStatus? = nil) throws -> [Issue] {
        let sql: String
        if status != nil {
            sql = "SELECT * FROM issues WHERE status = ? ORDER BY priority ASC, created_at ASC"
        } else {
            sql = "SELECT * FROM issues ORDER BY priority ASC, created_at ASC"
        }

        var issues: [Issue] = []

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                if let status = status {
                    AgentDatabase.bindText(stmt, index: 1, value: status.rawValue)
                }
            }
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let issue = parseIssueRow(stmt) {
                    issues.append(issue)
                }
            }
        }

        return issues
    }

    /// Lists issues for a specific task
    public static func listIssues(forTask taskId: String) throws -> [Issue] {
        let sql = "SELECT * FROM issues WHERE task_id = ? ORDER BY priority ASC, created_at ASC"
        var issues: [Issue] = []

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: taskId)
            }
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let issue = parseIssueRow(stmt) {
                    issues.append(issue)
                }
            }
        }

        return issues
    }

    /// Gets ready issues - open issues with no unclosed blockers
    /// Sorted by priority (P0 first), then by age (oldest first)
    public static func readyIssues(forTask taskId: String? = nil) throws -> [Issue] {
        // Get open issues that don't have any unclosed blockers
        let sql: String
        if taskId != nil {
            sql = """
                    SELECT i.* FROM issues i
                    WHERE i.status = 'open'
                    AND i.task_id = ?
                    AND NOT EXISTS (
                        SELECT 1 FROM dependencies d
                        JOIN issues blocker ON d.from_issue_id = blocker.id
                        WHERE d.to_issue_id = i.id
                        AND d.type = 'blocks'
                        AND blocker.status != 'closed'
                    )
                    ORDER BY i.priority ASC, i.created_at ASC
                """
        } else {
            sql = """
                    SELECT i.* FROM issues i
                    WHERE i.status = 'open'
                    AND NOT EXISTS (
                        SELECT 1 FROM dependencies d
                        JOIN issues blocker ON d.from_issue_id = blocker.id
                        WHERE d.to_issue_id = i.id
                        AND d.type = 'blocks'
                        AND blocker.status != 'closed'
                    )
                    ORDER BY i.priority ASC, i.created_at ASC
                """
        }

        var issues: [Issue] = []

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                if let taskId = taskId {
                    AgentDatabase.bindText(stmt, index: 1, value: taskId)
                }
            }
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let issue = parseIssueRow(stmt) {
                    issues.append(issue)
                }
            }
        }

        return issues
    }

    /// Gets blocked issues - issues waiting on other issues
    public static func blockedIssues(forTask taskId: String? = nil) throws -> [Issue] {
        let sql: String
        if taskId != nil {
            sql = """
                    SELECT DISTINCT i.* FROM issues i
                    JOIN dependencies d ON d.to_issue_id = i.id
                    JOIN issues blocker ON d.from_issue_id = blocker.id
                    WHERE d.type = 'blocks'
                    AND blocker.status != 'closed'
                    AND i.task_id = ?
                    ORDER BY i.priority ASC, i.created_at ASC
                """
        } else {
            sql = """
                    SELECT DISTINCT i.* FROM issues i
                    JOIN dependencies d ON d.to_issue_id = i.id
                    JOIN issues blocker ON d.from_issue_id = blocker.id
                    WHERE d.type = 'blocks'
                    AND blocker.status != 'closed'
                    ORDER BY i.priority ASC, i.created_at ASC
                """
        }

        var issues: [Issue] = []

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                if let taskId = taskId {
                    AgentDatabase.bindText(stmt, index: 1, value: taskId)
                }
            }
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let issue = parseIssueRow(stmt) {
                    issues.append(issue)
                }
            }
        }

        return issues
    }

    /// Gets issues that are blocked by a specific issue
    public static func issuesBlockedBy(issueId: String) throws -> [Issue] {
        let sql = """
                SELECT i.* FROM issues i
                JOIN dependencies d ON d.to_issue_id = i.id
                WHERE d.from_issue_id = ?
                AND d.type = 'blocks'
                ORDER BY i.priority ASC, i.created_at ASC
            """

        var issues: [Issue] = []

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: issueId)
            }
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let issue = parseIssueRow(stmt) {
                    issues.append(issue)
                }
            }
        }

        return issues
    }

    // MARK: - Dependency Operations

    /// Creates a new dependency
    @discardableResult
    public static func createDependency(_ dependency: IssueDependency) throws -> IssueDependency {
        let sql = """
                INSERT INTO dependencies (id, from_issue_id, to_issue_id, type, created_at)
                VALUES (?, ?, ?, ?, ?)
            """

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: dependency.id)
                AgentDatabase.bindText(stmt, index: 2, value: dependency.fromIssueId)
                AgentDatabase.bindText(stmt, index: 3, value: dependency.toIssueId)
                AgentDatabase.bindText(stmt, index: 4, value: dependency.type.rawValue)
                AgentDatabase.bindDate(stmt, index: 5, value: dependency.createdAt)
            }
        ) { stmt in
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE {
                throw AgentDatabaseError.failedToExecute("Failed to insert dependency")
            }
        }

        return dependency
    }

    /// Gets dependencies for an issue (where issue is the target/blocked)
    public static func getDependencies(toIssueId: String) throws -> [IssueDependency] {
        let sql = "SELECT * FROM dependencies WHERE to_issue_id = ?"
        var deps: [IssueDependency] = []

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: toIssueId)
            }
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let dep = parseDependencyRow(stmt) {
                    deps.append(dep)
                }
            }
        }

        return deps
    }

    /// Gets dependencies where issue is the source/blocker
    public static func getDependencies(fromIssueId: String) throws -> [IssueDependency] {
        let sql = "SELECT * FROM dependencies WHERE from_issue_id = ?"
        var deps: [IssueDependency] = []

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: fromIssueId)
            }
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let dep = parseDependencyRow(stmt) {
                    deps.append(dep)
                }
            }
        }

        return deps
    }

    /// Deletes a dependency by ID
    public static func deleteDependency(id: String) throws {
        let sql = "DELETE FROM dependencies WHERE id = ?"

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: id)
            }
        ) { stmt in
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE {
                throw AgentDatabaseError.failedToExecute("Failed to delete dependency")
            }
        }
    }

    // MARK: - Event Operations

    /// Creates a new event
    @discardableResult
    public static func createEvent(_ event: IssueEvent) throws -> IssueEvent {
        let sql = """
                INSERT INTO events (id, issue_id, event_type, payload, created_at)
                VALUES (?, ?, ?, ?, ?)
            """

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: event.id)
                AgentDatabase.bindText(stmt, index: 2, value: event.issueId)
                AgentDatabase.bindText(stmt, index: 3, value: event.eventType.rawValue)
                AgentDatabase.bindText(stmt, index: 4, value: event.payload)
                AgentDatabase.bindDate(stmt, index: 5, value: event.createdAt)
            }
        ) { stmt in
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE {
                throw AgentDatabaseError.failedToExecute("Failed to insert event")
            }
        }

        return event
    }

    /// Gets event history for an issue
    public static func getHistory(issueId: String) throws -> [IssueEvent] {
        let sql = "SELECT * FROM events WHERE issue_id = ? ORDER BY created_at ASC"
        var events: [IssueEvent] = []

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: issueId)
            }
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let event = parseEventRow(stmt) {
                    events.append(event)
                }
            }
        }

        return events
    }

    // MARK: - Task Operations

    /// Creates a new task
    @discardableResult
    public static func createTask(_ task: AgentTask) throws -> AgentTask {
        let sql = """
                INSERT INTO tasks (id, title, query, persona_id, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: task.id)
                AgentDatabase.bindText(stmt, index: 2, value: task.title)
                AgentDatabase.bindText(stmt, index: 3, value: task.query)
                AgentDatabase.bindText(stmt, index: 4, value: task.personaId?.uuidString)
                AgentDatabase.bindText(stmt, index: 5, value: task.status.rawValue)
                AgentDatabase.bindDate(stmt, index: 6, value: task.createdAt)
                AgentDatabase.bindDate(stmt, index: 7, value: task.updatedAt)
            }
        ) { stmt in
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE {
                throw AgentDatabaseError.failedToExecute("Failed to insert task")
            }
        }

        return task
    }

    /// Gets a task by ID
    public static func getTask(id: String) throws -> AgentTask? {
        let sql = "SELECT * FROM tasks WHERE id = ?"
        var task: AgentTask?

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: id)
            }
        ) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                task = parseTaskRow(stmt)
            }
        }

        return task
    }

    /// Updates a task
    public static func updateTask(_ task: AgentTask) throws {
        let sql = """
                UPDATE tasks
                SET title = ?, status = ?, updated_at = ?
                WHERE id = ?
            """

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: task.title)
                AgentDatabase.bindText(stmt, index: 2, value: task.status.rawValue)
                AgentDatabase.bindDate(stmt, index: 3, value: Date())
                AgentDatabase.bindText(stmt, index: 4, value: task.id)
            }
        ) { stmt in
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE {
                throw AgentDatabaseError.failedToExecute("Failed to update task")
            }
        }
    }

    /// Deletes a task and all its issues
    public static func deleteTask(id: String) throws {
        // Delete all issues for this task first (cascades to deps and events)
        let deleteIssuesSql = "DELETE FROM issues WHERE task_id = ?"
        try AgentDatabase.shared.prepareAndExecute(
            deleteIssuesSql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: id)
            }
        ) { stmt in
            _ = sqlite3_step(stmt)
        }

        // Delete the task
        let sql = "DELETE FROM tasks WHERE id = ?"
        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: id)
            }
        ) { stmt in
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE {
                throw AgentDatabaseError.failedToExecute("Failed to delete task")
            }
        }
    }

    /// Lists all tasks, optionally filtered by persona
    public static func listTasks(personaId: UUID? = nil, status: AgentTaskStatus? = nil) throws -> [AgentTask] {
        var conditions: [String] = []
        if personaId != nil { conditions.append("persona_id = ?") }
        if status != nil { conditions.append("status = ?") }

        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = "SELECT * FROM tasks \(whereClause) ORDER BY updated_at DESC"

        var tasks: [AgentTask] = []
        var paramIndex: Int32 = 1

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                if let personaId = personaId {
                    AgentDatabase.bindText(stmt, index: paramIndex, value: personaId.uuidString)
                    paramIndex += 1
                }
                if let status = status {
                    AgentDatabase.bindText(stmt, index: paramIndex, value: status.rawValue)
                }
            }
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let task = parseTaskRow(stmt) {
                    tasks.append(task)
                }
            }
        }

        return tasks
    }

    // MARK: - Row Parsing

    private static func parseIssueRow(_ stmt: OpaquePointer) -> Issue? {
        guard let id = AgentDatabase.getText(stmt, column: 0),
            let taskId = AgentDatabase.getText(stmt, column: 1),
            let title = AgentDatabase.getText(stmt, column: 2),
            let statusRaw = AgentDatabase.getText(stmt, column: 5),
            let status = IssueStatus(rawValue: statusRaw),
            let typeRaw = AgentDatabase.getText(stmt, column: 7),
            let type = IssueType(rawValue: typeRaw),
            let createdAt = AgentDatabase.getDate(stmt, column: 9),
            let updatedAt = AgentDatabase.getDate(stmt, column: 10)
        else { return nil }

        let description = AgentDatabase.getText(stmt, column: 3)
        let context = AgentDatabase.getText(stmt, column: 4)
        let priority = IssuePriority(rawValue: AgentDatabase.getInt(stmt, column: 6)) ?? .p2
        let result = AgentDatabase.getText(stmt, column: 8)

        return Issue(
            id: id,
            taskId: taskId,
            title: title,
            description: description,
            context: context,
            status: status,
            priority: priority,
            type: type,
            result: result,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func parseDependencyRow(_ stmt: OpaquePointer) -> IssueDependency? {
        guard let id = AgentDatabase.getText(stmt, column: 0),
            let fromId = AgentDatabase.getText(stmt, column: 1),
            let toId = AgentDatabase.getText(stmt, column: 2),
            let typeRaw = AgentDatabase.getText(stmt, column: 3),
            let type = DependencyType(rawValue: typeRaw),
            let createdAt = AgentDatabase.getDate(stmt, column: 4)
        else { return nil }

        return IssueDependency(
            id: id,
            fromIssueId: fromId,
            toIssueId: toId,
            type: type,
            createdAt: createdAt
        )
    }

    private static func parseEventRow(_ stmt: OpaquePointer) -> IssueEvent? {
        guard let id = AgentDatabase.getText(stmt, column: 0),
            let issueId = AgentDatabase.getText(stmt, column: 1),
            let eventTypeRaw = AgentDatabase.getText(stmt, column: 2),
            let eventType = IssueEventType(rawValue: eventTypeRaw),
            let createdAt = AgentDatabase.getDate(stmt, column: 4)
        else { return nil }

        let payload = AgentDatabase.getText(stmt, column: 3)

        return IssueEvent(
            id: id,
            issueId: issueId,
            eventType: eventType,
            payload: payload,
            createdAt: createdAt
        )
    }

    private static func parseTaskRow(_ stmt: OpaquePointer) -> AgentTask? {
        guard let id = AgentDatabase.getText(stmt, column: 0),
            let title = AgentDatabase.getText(stmt, column: 1),
            let query = AgentDatabase.getText(stmt, column: 2),
            let statusRaw = AgentDatabase.getText(stmt, column: 4),
            let status = AgentTaskStatus(rawValue: statusRaw),
            let createdAt = AgentDatabase.getDate(stmt, column: 5),
            let updatedAt = AgentDatabase.getDate(stmt, column: 6)
        else { return nil }

        let personaIdString = AgentDatabase.getText(stmt, column: 3)
        let personaId = personaIdString.flatMap { UUID(uuidString: $0) }

        return AgentTask(
            id: id,
            title: title,
            query: query,
            personaId: personaId,
            status: status,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - Artifact Operations

    /// Creates a new artifact in the database
    @discardableResult
    public static func createArtifact(_ artifact: Artifact) throws -> Artifact {
        let sql = """
                INSERT INTO artifacts (id, task_id, filename, content, content_type, is_final_result, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: artifact.id)
                AgentDatabase.bindText(stmt, index: 2, value: artifact.taskId)
                AgentDatabase.bindText(stmt, index: 3, value: artifact.filename)
                AgentDatabase.bindText(stmt, index: 4, value: artifact.content)
                AgentDatabase.bindText(stmt, index: 5, value: artifact.contentType.rawValue)
                AgentDatabase.bindInt(stmt, index: 6, value: artifact.isFinalResult ? 1 : 0)
                AgentDatabase.bindDate(stmt, index: 7, value: artifact.createdAt)
            }
        ) { stmt in
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE {
                throw AgentDatabaseError.failedToExecute("Failed to insert artifact")
            }
        }

        return artifact
    }

    /// Gets an artifact by ID
    public static func getArtifact(id: String) throws -> Artifact? {
        let sql = "SELECT * FROM artifacts WHERE id = ?"
        var artifact: Artifact?

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: id)
            }
        ) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                artifact = parseArtifactRow(stmt)
            }
        }

        return artifact
    }

    /// Lists all artifacts for a specific task
    public static func listArtifacts(forTask taskId: String) throws -> [Artifact] {
        let sql = "SELECT * FROM artifacts WHERE task_id = ? ORDER BY created_at ASC"
        var artifacts: [Artifact] = []

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: taskId)
            }
        ) { stmt in
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let artifact = parseArtifactRow(stmt) {
                    artifacts.append(artifact)
                }
            }
        }

        return artifacts
    }

    /// Gets the final result artifact for a task (if any)
    public static func getFinalArtifact(forTask taskId: String) throws -> Artifact? {
        let sql = "SELECT * FROM artifacts WHERE task_id = ? AND is_final_result = 1 ORDER BY created_at DESC LIMIT 1"
        var artifact: Artifact?

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: taskId)
            }
        ) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW {
                artifact = parseArtifactRow(stmt)
            }
        }

        return artifact
    }

    /// Deletes an artifact by ID
    public static func deleteArtifact(id: String) throws {
        let sql = "DELETE FROM artifacts WHERE id = ?"

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: id)
            }
        ) { stmt in
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE {
                throw AgentDatabaseError.failedToExecute("Failed to delete artifact")
            }
        }
    }

    /// Deletes all artifacts for a task
    public static func deleteArtifacts(forTask taskId: String) throws {
        let sql = "DELETE FROM artifacts WHERE task_id = ?"

        try AgentDatabase.shared.prepareAndExecute(
            sql,
            bind: { stmt in
                AgentDatabase.bindText(stmt, index: 1, value: taskId)
            }
        ) { stmt in
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE {
                throw AgentDatabaseError.failedToExecute("Failed to delete artifacts for task")
            }
        }
    }

    private static func parseArtifactRow(_ stmt: OpaquePointer) -> Artifact? {
        guard let id = AgentDatabase.getText(stmt, column: 0),
            let taskId = AgentDatabase.getText(stmt, column: 1),
            let filename = AgentDatabase.getText(stmt, column: 2),
            let content = AgentDatabase.getText(stmt, column: 3),
            let contentTypeRaw = AgentDatabase.getText(stmt, column: 4),
            let contentType = ArtifactContentType(rawValue: contentTypeRaw),
            let createdAt = AgentDatabase.getDate(stmt, column: 6)
        else { return nil }

        let isFinalResult = AgentDatabase.getInt(stmt, column: 5) == 1

        return Artifact(
            id: id,
            taskId: taskId,
            filename: filename,
            content: content,
            contentType: contentType,
            isFinalResult: isFinalResult,
            createdAt: createdAt
        )
    }
}
