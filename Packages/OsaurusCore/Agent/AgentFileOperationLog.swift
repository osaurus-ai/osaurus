//
//  AgentFileOperationLog.swift
//  osaurus
//
//  Actor for managing file operation history and undo functionality.
//

import Foundation

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a file operation is logged or undone
    public static let agentFileOperationsDidChange = Notification.Name("agentFileOperationsDidChange")
}

// MARK: - Undo Errors

public enum AgentFileUndoError: LocalizedError {
    case operationNotFound
    case cannotUndo(String)
    case fileSystemError(String)

    public var errorDescription: String? {
        switch self {
        case .operationNotFound:
            return "Operation not found in history"
        case .cannotUndo(let reason):
            return "Cannot undo: \(reason)"
        case .fileSystemError(let msg):
            return "File system error: \(msg)"
        }
    }
}

// MARK: - File Operation Log

/// Actor for managing file operation history per issue
public actor AgentFileOperationLog {
    public static let shared = AgentFileOperationLog()

    /// Operations grouped by issue ID (most recent last)
    private var operations: [String: [AgentFileOperation]] = [:]

    /// Root path for file operations (set when folder context is active)
    private var rootPath: URL?

    private init() {}

    // MARK: - Configuration

    /// Set the root path for undo operations
    public func setRootPath(_ url: URL?) {
        rootPath = url
    }

    // MARK: - Logging

    /// Log a file operation
    public func log(_ operation: AgentFileOperation) {
        operations[operation.issueId, default: []].append(operation)
        notifyChange()
    }

    /// Post notification that operations changed (on main thread)
    private func notifyChange() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .agentFileOperationsDidChange, object: nil)
        }
    }

    // MARK: - Queries

    /// Get all operations for an issue (oldest first)
    public func operations(for issueId: String) -> [AgentFileOperation] {
        operations[issueId] ?? []
    }

    /// Get operations for a specific file path within an issue
    public func operations(for issueId: String, path: String) -> [AgentFileOperation] {
        operations[issueId]?.filter { $0.path == path } ?? []
    }

    /// Get unique file paths affected by operations for an issue
    public func affectedPaths(for issueId: String) -> [String] {
        let ops = operations[issueId] ?? []
        var seen = Set<String>()
        var result: [String] = []
        for op in ops {
            if !seen.contains(op.path) {
                seen.insert(op.path)
                result.append(op.path)
            }
            if let dest = op.destinationPath, !seen.contains(dest) {
                seen.insert(dest)
                result.append(dest)
            }
        }
        return result
    }

    /// Check if there are any operations for an issue
    public func hasOperations(for issueId: String) -> Bool {
        !(operations[issueId]?.isEmpty ?? true)
    }

    // MARK: - Undo Operations

    /// Undo the last operation for an issue
    @discardableResult
    public func undoLast(issueId: String) throws -> AgentFileOperation? {
        guard var issueOps = operations[issueId], !issueOps.isEmpty else {
            return nil
        }

        let operation = issueOps.removeLast()
        operations[issueId] = issueOps

        try performUndo(operation)
        notifyChange()
        return operation
    }

    /// Undo all operations for an issue (in reverse order)
    @discardableResult
    public func undoAll(issueId: String) throws -> [AgentFileOperation] {
        guard let issueOps = operations[issueId], !issueOps.isEmpty else {
            return []
        }

        var undone: [AgentFileOperation] = []

        // Undo in reverse order
        for operation in issueOps.reversed() {
            do {
                try performUndo(operation)
                undone.append(operation)
            } catch {
                // Continue undoing remaining operations even if one fails
                continue
            }
        }

        operations[issueId] = []
        notifyChange()
        return undone
    }

    /// Undo operations for a specific file path
    @discardableResult
    public func undoFile(issueId: String, path: String) throws -> [AgentFileOperation] {
        guard var issueOps = operations[issueId] else {
            return []
        }

        let fileOps = issueOps.filter { $0.path == path || $0.destinationPath == path }
        guard !fileOps.isEmpty else { return [] }

        var undone: [AgentFileOperation] = []

        // Undo in reverse order
        for operation in fileOps.reversed() {
            do {
                try performUndo(operation)
                undone.append(operation)
            } catch {
                continue
            }
        }

        // Remove undone operations from the list
        let undoneIds = Set(undone.map { $0.id })
        issueOps.removeAll { undoneIds.contains($0.id) }
        operations[issueId] = issueOps

        notifyChange()
        return undone
    }

    /// Undo a specific operation by ID
    @discardableResult
    public func undo(issueId: String, operationId: UUID) throws -> AgentFileOperation? {
        guard var issueOps = operations[issueId],
            let index = issueOps.firstIndex(where: { $0.id == operationId })
        else {
            throw AgentFileUndoError.operationNotFound
        }

        let operation = issueOps[index]
        try performUndo(operation)

        issueOps.remove(at: index)
        operations[issueId] = issueOps

        notifyChange()
        return operation
    }

    // MARK: - Cleanup

    /// Clear all operations for an issue
    public func clear(issueId: String) {
        operations[issueId] = nil
    }

    /// Clear all operations
    public func clearAll() {
        operations.removeAll()
    }

    // MARK: - Private Undo Implementation

    private func performUndo(_ operation: AgentFileOperation) throws {
        guard let root = rootPath else {
            throw AgentFileUndoError.cannotUndo("No root path configured")
        }

        let fm = FileManager.default
        let fileURL = root.appendingPathComponent(operation.path)

        switch operation.type {
        case .create:
            // Undo create: delete the file
            if fm.fileExists(atPath: fileURL.path) {
                do {
                    try fm.removeItem(at: fileURL)
                } catch {
                    throw AgentFileUndoError.fileSystemError(
                        "Failed to delete created file: \(error.localizedDescription)"
                    )
                }
            }

        case .write:
            // Undo write: restore previous content or delete if it was new
            if let previousContent = operation.previousContent {
                do {
                    try previousContent.write(to: fileURL, atomically: true, encoding: .utf8)
                } catch {
                    throw AgentFileUndoError.fileSystemError(
                        "Failed to restore file content: \(error.localizedDescription)"
                    )
                }
            } else {
                // File didn't exist before, delete it
                if fm.fileExists(atPath: fileURL.path) {
                    try? fm.removeItem(at: fileURL)
                }
            }

        case .move:
            // Undo move: move back from destination to source
            guard let destPath = operation.destinationPath else {
                throw AgentFileUndoError.cannotUndo("Move operation missing destination path")
            }
            let destURL = root.appendingPathComponent(destPath)

            if fm.fileExists(atPath: destURL.path) {
                do {
                    // Ensure source parent directory exists
                    let parentDir = fileURL.deletingLastPathComponent()
                    try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                    try fm.moveItem(at: destURL, to: fileURL)
                } catch {
                    throw AgentFileUndoError.fileSystemError("Failed to move file back: \(error.localizedDescription)")
                }
            }

        case .copy:
            // Undo copy: delete the destination
            guard let destPath = operation.destinationPath else {
                throw AgentFileUndoError.cannotUndo("Copy operation missing destination path")
            }
            let destURL = root.appendingPathComponent(destPath)

            if fm.fileExists(atPath: destURL.path) {
                do {
                    try fm.removeItem(at: destURL)
                } catch {
                    throw AgentFileUndoError.fileSystemError(
                        "Failed to delete copied file: \(error.localizedDescription)"
                    )
                }
            }

        case .delete:
            // Undo delete: recreate file from previous content
            guard let previousContent = operation.previousContent else {
                throw AgentFileUndoError.cannotUndo("Delete operation missing previous content")
            }

            do {
                // Ensure parent directory exists
                let parentDir = fileURL.deletingLastPathComponent()
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                try previousContent.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                throw AgentFileUndoError.fileSystemError(
                    "Failed to restore deleted file: \(error.localizedDescription)"
                )
            }

        case .dirCreate:
            // Undo dirCreate: remove directory if empty
            if fm.fileExists(atPath: fileURL.path) {
                let contents = (try? fm.contentsOfDirectory(atPath: fileURL.path)) ?? []
                if contents.isEmpty {
                    do {
                        try fm.removeItem(at: fileURL)
                    } catch {
                        throw AgentFileUndoError.fileSystemError(
                            "Failed to remove directory: \(error.localizedDescription)"
                        )
                    }
                } else {
                    throw AgentFileUndoError.cannotUndo("Directory is not empty")
                }
            }
        }
    }
}
