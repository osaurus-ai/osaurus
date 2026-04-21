//
//  FileOperationLog.swift
//  osaurus
//
//  Actor for managing file operation history and undo functionality.
//

import Foundation

// MARK: - Notifications

extension Notification.Name {
    /// Posted when a file operation is logged or undone
    public static let fileOperationsDidChange = Notification.Name("fileOperationsDidChange")
}

// MARK: - Undo Errors

public enum FileUndoError: LocalizedError {
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

/// Actor for managing folder file-operation history per chat session.
public actor FileOperationLog {
    public static let shared = FileOperationLog()

    /// Operations grouped by chat session id (most recent last)
    private var operations: [String: [FileOperation]] = [:]

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
    public func log(_ operation: FileOperation) {
        operations[operation.sessionId, default: []].append(operation)
        notifyChange()
    }

    /// Post notification that operations changed (on main thread)
    private func notifyChange() {
        Task { @MainActor in
            NotificationCenter.default.post(name: .fileOperationsDidChange, object: nil)
        }
    }

    // MARK: - Queries

    /// Get all operations for a session (oldest first)
    public func operations(for sessionId: String) -> [FileOperation] {
        operations[sessionId] ?? []
    }

    /// Get operations for a specific file path within a session
    public func operations(for sessionId: String, path: String) -> [FileOperation] {
        operations[sessionId]?.filter { $0.path == path } ?? []
    }

    /// Get unique file paths affected by operations for a session
    public func affectedPaths(for sessionId: String) -> [String] {
        let ops = operations[sessionId] ?? []
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

    /// Check if there are any operations for a session
    public func hasOperations(for sessionId: String) -> Bool {
        !(operations[sessionId]?.isEmpty ?? true)
    }

    // MARK: - Undo Operations

    /// Undo the last operation for a session
    @discardableResult
    public func undoLast(sessionId: String) throws -> FileOperation? {
        guard var sessionOps = operations[sessionId], !sessionOps.isEmpty else {
            return nil
        }

        let operation = sessionOps.removeLast()
        operations[sessionId] = sessionOps

        try performUndo(operation)
        notifyChange()
        return operation
    }

    /// Undo all operations for a session (in reverse order)
    @discardableResult
    public func undoAll(sessionId: String) throws -> [FileOperation] {
        guard let sessionOps = operations[sessionId], !sessionOps.isEmpty else {
            return []
        }

        var undone: [FileOperation] = []

        // Undo in reverse order
        for operation in sessionOps.reversed() {
            do {
                try performUndo(operation)
                undone.append(operation)
            } catch {
                // Continue undoing remaining operations even if one fails
                continue
            }
        }

        operations[sessionId] = []
        notifyChange()
        return undone
    }

    /// Undo operations for a specific file path
    @discardableResult
    public func undoFile(sessionId: String, path: String) throws -> [FileOperation] {
        guard var sessionOps = operations[sessionId] else {
            return []
        }

        let fileOps = sessionOps.filter { $0.path == path || $0.destinationPath == path }
        guard !fileOps.isEmpty else { return [] }

        var undone: [FileOperation] = []

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
        sessionOps.removeAll { undoneIds.contains($0.id) }
        operations[sessionId] = sessionOps

        notifyChange()
        return undone
    }

    /// Undo a specific operation by ID
    @discardableResult
    public func undo(sessionId: String, operationId: UUID) throws -> FileOperation? {
        guard var sessionOps = operations[sessionId],
            let index = sessionOps.firstIndex(where: { $0.id == operationId })
        else {
            throw FileUndoError.operationNotFound
        }

        let operation = sessionOps[index]
        try performUndo(operation)

        sessionOps.remove(at: index)
        operations[sessionId] = sessionOps

        notifyChange()
        return operation
    }

    /// Undo all operations for a specific batch (in reverse order).
    /// Continues on error, returning only successfully undone operations.
    @discardableResult
    public func undoBatch(sessionId: String, batchId: UUID) throws -> [FileOperation] {
        guard var sessionOps = operations[sessionId] else {
            return []
        }

        let batchOps = sessionOps.filter { $0.batchId == batchId }
        guard !batchOps.isEmpty else { return [] }

        var undone: [FileOperation] = []

        // Undo in reverse order
        for operation in batchOps.reversed() {
            do {
                try performUndo(operation)
                undone.append(operation)
            } catch {
                // Continue undoing remaining operations even if one fails
                continue
            }
        }

        // Remove undone operations from the list
        let undoneIds = Set(undone.map { $0.id })
        sessionOps.removeAll { undoneIds.contains($0.id) }
        operations[sessionId] = sessionOps

        notifyChange()
        return undone
    }

    // MARK: - Cleanup

    /// Clear all operations for a session
    public func clear(sessionId: String) {
        operations[sessionId] = nil
    }

    /// Clear all operations
    public func clearAll() {
        operations.removeAll()
    }

    // MARK: - Private Undo Implementation

    private func performUndo(_ operation: FileOperation) throws {
        guard let root = rootPath else {
            throw FileUndoError.cannotUndo("No root path configured")
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
                    throw FileUndoError.fileSystemError(
                        "Failed to delete created file: \(error.localizedDescription)"
                    )
                }
            }

        case .write, .fileEdit:
            // Undo write/edit: restore previous content or delete if it was new.
            // file_edit always supplies previousContent (the full pre-edit
            // file body) so undo just rewrites the file in place.
            if let previousContent = operation.previousContent {
                do {
                    try previousContent.write(to: fileURL, atomically: true, encoding: .utf8)
                } catch {
                    throw FileUndoError.fileSystemError(
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
                throw FileUndoError.cannotUndo("Move operation missing destination path")
            }
            let destURL = root.appendingPathComponent(destPath)

            if fm.fileExists(atPath: destURL.path) {
                do {
                    // Ensure source parent directory exists
                    let parentDir = fileURL.deletingLastPathComponent()
                    try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                    try fm.moveItem(at: destURL, to: fileURL)
                } catch {
                    throw FileUndoError.fileSystemError("Failed to move file back: \(error.localizedDescription)")
                }
            }

        case .copy:
            // Undo copy: delete the destination
            guard let destPath = operation.destinationPath else {
                throw FileUndoError.cannotUndo("Copy operation missing destination path")
            }
            let destURL = root.appendingPathComponent(destPath)

            if fm.fileExists(atPath: destURL.path) {
                do {
                    try fm.removeItem(at: destURL)
                } catch {
                    throw FileUndoError.fileSystemError(
                        "Failed to delete copied file: \(error.localizedDescription)"
                    )
                }
            }

        case .delete:
            // Undo delete: recreate file from previous content
            guard let previousContent = operation.previousContent else {
                throw FileUndoError.cannotUndo("Delete operation missing previous content")
            }

            do {
                // Ensure parent directory exists
                let parentDir = fileURL.deletingLastPathComponent()
                try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
                try previousContent.write(to: fileURL, atomically: true, encoding: .utf8)
            } catch {
                throw FileUndoError.fileSystemError(
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
                        throw FileUndoError.fileSystemError(
                            "Failed to remove directory: \(error.localizedDescription)"
                        )
                    }
                } else {
                    throw FileUndoError.cannotUndo("Directory is not empty")
                }
            }
        }
    }
}
