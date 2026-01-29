//
//  IssueManager.swift
//  osaurus
//
//  Manager for issue lifecycle in Osaurus Agents.
//  Handles issue creation, status transitions, and dependency management.
//

import Foundation

/// Manager for issue lifecycle operations
@MainActor
public final class IssueManager: ObservableObject {
    /// Shared singleton instance
    public static let shared = IssueManager()

    /// Published list of all issues (for UI binding)
    @Published public private(set) var issues: [Issue] = []

    /// Published list of all tasks (for UI binding)
    @Published public private(set) var tasks: [AgentTask] = []

    /// Currently active task
    @Published public private(set) var activeTask: AgentTask?

    /// Whether the database is initialized
    @Published public private(set) var isInitialized = false

    private init() {}

    // MARK: - Initialization

    /// Initialize the manager and open the database
    public func initialize() async throws {
        guard !isInitialized else { return }

        try AgentDatabase.shared.open()
        isInitialized = true

        // Load initial data
        await refreshTasks()
    }

    /// Shutdown the manager
    public func shutdown() {
        AgentDatabase.shared.close()
        isInitialized = false
        issues = []
        tasks = []
        activeTask = nil
    }

    // MARK: - Task Operations

    /// Creates a new task from a user query
    public func createTask(query: String, personaId: UUID? = nil) async throws -> AgentTask {
        let task = AgentTask(
            title: AgentTask.generateTitle(from: query),
            query: query,
            personaId: personaId
        )

        try IssueStore.createTask(task)

        // Create the initial issue for this task
        let issue = Issue(
            taskId: task.id,
            title: task.title,
            description: query
        )
        try IssueStore.createIssue(issue)

        // Log the creation event
        try IssueStore.createEvent(
            IssueEvent.withPayload(
                issueId: issue.id,
                eventType: .created,
                payload: ["query": query]
            )
        )

        await refreshTasks()
        await loadIssues(forTask: task.id)

        return task
    }

    /// Sets the active task
    public func setActiveTask(_ task: AgentTask?) async {
        activeTask = task
        if let task = task {
            await loadIssues(forTask: task.id)
        } else {
            issues = []
        }
    }

    /// Updates a task's status
    public func updateTaskStatus(_ taskId: String, status: AgentTaskStatus) async throws {
        guard var task = try IssueStore.getTask(id: taskId) else {
            throw IssueManagerError.taskNotFound(taskId)
        }

        task.status = status
        try IssueStore.updateTask(task)

        await refreshTasks()

        if activeTask?.id == taskId {
            activeTask = task
        }
    }

    /// Deletes a task and all its issues
    public func deleteTask(_ taskId: String) async throws {
        try IssueStore.deleteTask(id: taskId)

        if activeTask?.id == taskId {
            activeTask = nil
            issues = []
        }

        await refreshTasks()
    }

    /// Refreshes the task list from the database
    public func refreshTasks(personaId: UUID? = nil) async {
        do {
            tasks = try IssueStore.listTasks(personaId: personaId)
        } catch {
            print("[IssueManager] Failed to refresh tasks: \(error)")
            tasks = []
        }
    }

    // MARK: - Issue Operations

    /// Creates a new issue
    public func createIssue(
        taskId: String,
        title: String,
        description: String? = nil,
        context: String? = nil,
        priority: IssuePriority = .p2,
        type: IssueType = .task
    ) async throws -> Issue {
        let issue = Issue(
            taskId: taskId,
            title: title,
            description: description,
            context: context,
            priority: priority,
            type: type
        )

        try IssueStore.createIssue(issue)

        // Log the creation event
        try IssueStore.createEvent(
            IssueEvent(
                issueId: issue.id,
                eventType: .created
            )
        )

        await loadIssues(forTask: taskId)
        return issue
    }

    /// Updates an issue's status with validation
    public func updateIssueStatus(_ issueId: String, to newStatus: IssueStatus) async throws {
        guard var issue = try IssueStore.getIssue(id: issueId) else {
            throw IssueManagerError.issueNotFound(issueId)
        }

        let oldStatus = issue.status

        // Validate status transition
        guard isValidTransition(from: oldStatus, to: newStatus) else {
            throw IssueManagerError.invalidStatusTransition(from: oldStatus, to: newStatus)
        }

        issue.status = newStatus
        issue.updatedAt = Date()

        try IssueStore.updateIssue(issue)

        // Log the status change event
        try IssueStore.createEvent(
            IssueEvent.withPayload(
                issueId: issueId,
                eventType: .statusChanged,
                payload: ["from": oldStatus.rawValue, "to": newStatus.rawValue]
            )
        )

        // If closing an issue, check if it unblocks others
        if newStatus == .closed {
            try await updateBlockedIssues(afterClosing: issueId)
        }

        await loadIssues(forTask: issue.taskId)
    }

    /// Closes an issue with a result summary
    public func closeIssue(_ issueId: String, result: String) async throws {
        guard var issue = try IssueStore.getIssue(id: issueId) else {
            throw IssueManagerError.issueNotFound(issueId)
        }

        let oldStatus = issue.status
        issue.status = .closed
        issue.result = result
        issue.updatedAt = Date()

        try IssueStore.updateIssue(issue)

        // Log events
        try IssueStore.createEvent(
            IssueEvent.withPayload(
                issueId: issueId,
                eventType: .statusChanged,
                payload: ["from": oldStatus.rawValue, "to": "closed"]
            )
        )
        try IssueStore.createEvent(
            IssueEvent.withPayload(
                issueId: issueId,
                eventType: .closed,
                payload: ["result": result]
            )
        )

        // Check if it unblocks others
        try await updateBlockedIssues(afterClosing: issueId)

        // Check if all issues in task are closed
        await checkTaskCompletion(taskId: issue.taskId)

        await loadIssues(forTask: issue.taskId)
    }

    /// Marks an issue as in progress
    public func startIssue(_ issueId: String) async throws {
        try await updateIssueStatus(issueId, to: .inProgress)

        // Log execution started event
        try IssueStore.createEvent(
            IssueEvent(
                issueId: issueId,
                eventType: .executionStarted
            )
        )
    }

    /// Gets the next ready issue for a task (highest priority, oldest)
    public func nextReadyIssue(forTask taskId: String) async throws -> Issue? {
        let ready = try IssueStore.readyIssues(forTask: taskId)
        return ready.first
    }

    /// Gets all ready issues
    public func readyIssues(forTask taskId: String? = nil) async throws -> [Issue] {
        try IssueStore.readyIssues(forTask: taskId)
    }

    /// Gets all blocked issues
    public func blockedIssues(forTask taskId: String? = nil) async throws -> [Issue] {
        try IssueStore.blockedIssues(forTask: taskId)
    }

    /// Loads issues for a task
    public func loadIssues(forTask taskId: String) async {
        do {
            issues = try IssueStore.listIssues(forTask: taskId)
        } catch {
            print("[IssueManager] Failed to load issues: \(error)")
            issues = []
        }
    }

    /// Gets an issue by ID
    public func getIssue(_ issueId: String) throws -> Issue? {
        try IssueStore.getIssue(id: issueId)
    }

    /// Gets event history for an issue
    public func getHistory(issueId: String) throws -> [IssueEvent] {
        try IssueStore.getHistory(issueId: issueId)
    }

    // MARK: - Dependency Operations

    /// Adds a blocking dependency (fromIssue blocks toIssue)
    public func addBlocker(fromIssueId: String, toIssueId: String) async throws {
        // Prevent self-blocking
        guard fromIssueId != toIssueId else {
            throw IssueManagerError.wouldCreateCycle(from: fromIssueId, to: toIssueId)
        }

        // Check for cycles before adding
        if try wouldCreateCycle(from: fromIssueId, to: toIssueId) {
            throw IssueManagerError.wouldCreateCycle(from: fromIssueId, to: toIssueId)
        }

        let dependency = IssueDependency(
            fromIssueId: fromIssueId,
            toIssueId: toIssueId,
            type: .blocks
        )

        try IssueStore.createDependency(dependency)

        // Log the event
        try IssueStore.createEvent(
            IssueEvent.withPayload(
                issueId: toIssueId,
                eventType: .dependencyAdded,
                payload: ["blocker": fromIssueId, "type": "blocks"]
            )
        )

        // Update the blocked issue's status if needed
        if let issue = try IssueStore.getIssue(id: toIssueId), issue.status == .open {
            try await updateIssueStatus(toIssueId, to: .blocked)
        }
    }

    /// Checks if adding a blocker would create a cycle
    /// Returns true if 'to' already blocks 'from' (directly or transitively)
    private func wouldCreateCycle(from: String, to: String) throws -> Bool {
        var visited = Set<String>()
        var queue = [to]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current == from { return true }
            if visited.contains(current) { continue }
            visited.insert(current)

            // Get issues that 'current' blocks
            let deps = try IssueStore.getDependencies(fromIssueId: current)
            for dep in deps where dep.type == .blocks {
                queue.append(dep.toIssueId)
            }
        }
        return false
    }

    /// Adds a parent-child relationship
    public func addChildIssue(parentId: String, childId: String) async throws {
        let dependency = IssueDependency(
            fromIssueId: parentId,
            toIssueId: childId,
            type: .parentChild
        )

        try IssueStore.createDependency(dependency)

        // Log the event
        try IssueStore.createEvent(
            IssueEvent.withPayload(
                issueId: childId,
                eventType: .dependencyAdded,
                payload: ["parent": parentId, "type": "parent_child"]
            )
        )
    }

    /// Links a discovered issue to its source
    public func linkDiscovery(sourceIssueId: String, discoveredIssueId: String) async throws {
        let dependency = IssueDependency(
            fromIssueId: sourceIssueId,
            toIssueId: discoveredIssueId,
            type: .discoveredFrom
        )

        try IssueStore.createDependency(dependency)

        // Log the event
        try IssueStore.createEvent(
            IssueEvent.withPayload(
                issueId: discoveredIssueId,
                eventType: .dependencyAdded,
                payload: ["source": sourceIssueId, "type": "discovered_from"]
            )
        )
    }

    /// Gets blockers for an issue
    public func getBlockers(issueId: String) throws -> [Issue] {
        let deps = try IssueStore.getDependencies(toIssueId: issueId)
        let blockerDeps = deps.filter { $0.type == .blocks }

        var blockers: [Issue] = []
        for dep in blockerDeps {
            if let issue = try IssueStore.getIssue(id: dep.fromIssueId) {
                blockers.append(issue)
            }
        }
        return blockers
    }

    // MARK: - Decomposition

    /// Decomposes an issue into child issues
    /// Used when a plan exceeds the step limit
    public func decomposeIssue(
        _ issueId: String,
        into children: [(title: String, description: String?, context: String?)]
    ) async throws
        -> [Issue]
    {
        guard var parentIssue = try IssueStore.getIssue(id: issueId) else {
            throw IssueManagerError.issueNotFound(issueId)
        }

        var createdIssues: [Issue] = []
        var previousIssueId: String?

        for child in children {
            let childIssue = try await createIssue(
                taskId: parentIssue.taskId,
                title: child.title,
                description: child.description,
                context: child.context,
                priority: parentIssue.priority,
                type: parentIssue.type
            )

            // Link to parent
            try await addChildIssue(parentId: issueId, childId: childIssue.id)

            // Chain dependencies: each chunk is blocked by the previous
            if let prevId = previousIssueId {
                try await addBlocker(fromIssueId: prevId, toIssueId: childIssue.id)
            }

            previousIssueId = childIssue.id
            createdIssues.append(childIssue)
        }

        // Log the decomposition
        try IssueStore.createEvent(
            IssueEvent.withPayload(
                issueId: issueId,
                eventType: .decomposed,
                payload: EventPayload.ChildCount(childCount: children.count)
            )
        )

        // Close parent as decomposed
        parentIssue.status = .closed
        parentIssue.result = "Decomposed into \(children.count) child issues"
        try IssueStore.updateIssue(parentIssue)

        await loadIssues(forTask: parentIssue.taskId)

        return createdIssues
    }

    // MARK: - Private Helpers

    /// Validates if a status transition is allowed
    private func isValidTransition(from: IssueStatus, to: IssueStatus) -> Bool {
        switch (from, to) {
        case (.open, .inProgress), (.open, .closed), (.open, .blocked):
            return true
        case (.inProgress, .closed), (.inProgress, .open), (.inProgress, .blocked):
            return true
        case (.blocked, .open):
            return true
        case (let a, let b) where a == b:
            return true  // No-op is valid
        default:
            return false
        }
    }

    /// Updates issues that were blocked by a now-closed issue
    private func updateBlockedIssues(afterClosing issueId: String) async throws {
        let blockedIssues = try IssueStore.issuesBlockedBy(issueId: issueId)

        for blockedIssue in blockedIssues {
            // Check if all blockers are now closed
            let blockers = try getBlockers(issueId: blockedIssue.id)
            let hasUnclosedBlockers = blockers.contains { $0.status != .closed }

            if !hasUnclosedBlockers && blockedIssue.status == .blocked {
                // Unblock the issue
                try await updateIssueStatus(blockedIssue.id, to: .open)
            }
        }
    }

    /// Checks if all issues in a task are closed and updates task status
    private func checkTaskCompletion(taskId: String) async {
        do {
            let taskIssues = try IssueStore.listIssues(forTask: taskId)
            let allClosed = taskIssues.allSatisfy { $0.status == .closed }

            if allClosed && !taskIssues.isEmpty {
                try await updateTaskStatus(taskId, status: .completed)
            }
        } catch {
            print("[IssueManager] Failed to check task completion: \(error)")
        }
    }

    // MARK: - Safe Methods for Actor Calls

    /// Generic wrapper that catches errors and logs them
    private func safe<T: Sendable>(
        _ operation: String,
        _ block: @Sendable () async throws -> T
    ) async -> T? {
        do {
            return try await block()
        } catch {
            print("[IssueManager] \(operation) failed: \(error)")
            return nil
        }
    }

    /// Creates a task without throwing (returns nil on failure)
    public func createTaskSafe(query: String, personaId: UUID? = nil) async -> AgentTask? {
        await safe("createTask") {
            try await createTask(query: query, personaId: personaId)
        }
    }

    /// Creates an issue without throwing (returns nil on failure)
    public func createIssueSafe(
        taskId: String,
        title: String,
        description: String? = nil,
        context: String? = nil,
        priority: IssuePriority = .p2,
        type: IssueType = .task
    ) async -> Issue? {
        await safe("createIssue") {
            try await createIssue(
                taskId: taskId,
                title: title,
                description: description,
                context: context,
                priority: priority,
                type: type
            )
        }
    }

    /// Closes an issue without throwing (returns success)
    public func closeIssueSafe(_ issueId: String, result: String) async -> Bool {
        await safe("closeIssue") {
            try await closeIssue(issueId, result: result)
        } != nil
    }

    /// Starts an issue without throwing (returns success)
    public func startIssueSafe(_ issueId: String) async -> Bool {
        await safe("startIssue") {
            try await startIssue(issueId)
        } != nil
    }

    /// Updates issue status without throwing (returns success)
    public func updateIssueStatusSafe(_ issueId: String, to status: IssueStatus) async -> Bool {
        await safe("updateIssueStatus") {
            try await updateIssueStatus(issueId, to: status)
        } != nil
    }

    /// Links a discovery without throwing (returns success)
    public func linkDiscoverySafe(sourceIssueId: String, discoveredIssueId: String) async -> Bool {
        await safe("linkDiscovery") {
            try await linkDiscovery(sourceIssueId: sourceIssueId, discoveredIssueId: discoveredIssueId)
        } != nil
    }

    /// Decomposes an issue without throwing (returns empty array on failure)
    public func decomposeIssueSafe(
        _ issueId: String,
        into children: [(title: String, description: String?, context: String?)]
    ) async -> [Issue] {
        await safe("decomposeIssue") {
            try await decomposeIssue(issueId, into: children)
        } ?? []
    }
}

// MARK: - Errors

/// Errors that can occur in IssueManager
public enum IssueManagerError: Error, LocalizedError {
    case issueNotFound(String)
    case taskNotFound(String)
    case invalidStatusTransition(from: IssueStatus, to: IssueStatus)
    case notInitialized
    case wouldCreateCycle(from: String, to: String)

    public var errorDescription: String? {
        switch self {
        case .issueNotFound(let id):
            return "Issue not found: \(id)"
        case .taskNotFound(let id):
            return "Task not found: \(id)"
        case .invalidStatusTransition(let from, let to):
            return "Invalid status transition from \(from.rawValue) to \(to.rawValue)"
        case .notInitialized:
            return "IssueManager is not initialized"
        case .wouldCreateCycle(let from, let to):
            return "Adding blocker would create a cycle: \(from) -> \(to)"
        }
    }
}
