//
//  WorkFileOperation.swift
//  osaurus
//
//  Models for tracking file operations for undo capability.
//

import Foundation

// MARK: - Operation Type

/// Type of file operation performed by work tools
public enum WorkFileOperationType: String, Codable, Sendable {
    case create  // New file created
    case write  // Existing file modified
    case move  // File/directory moved
    case copy  // File/directory copied
    case delete  // File/directory deleted
    case dirCreate  // New directory created
}

// MARK: - File Operation

/// A recorded file operation that can be undone
public struct WorkFileOperation: Codable, Sendable, Identifiable {
    public let id: UUID
    public let type: WorkFileOperationType
    public let path: String  // Relative path from root
    public let destinationPath: String?  // For move/copy operations
    public let previousContent: String?  // For write/delete (to restore)
    public let timestamp: Date
    public let issueId: String
    public let batchId: UUID?  // For batch operations (nil for non-batch)

    public init(
        id: UUID = UUID(),
        type: WorkFileOperationType,
        path: String,
        destinationPath: String? = nil,
        previousContent: String? = nil,
        timestamp: Date = Date(),
        issueId: String,
        batchId: UUID? = nil
    ) {
        self.id = id
        self.type = type
        self.path = path
        self.destinationPath = destinationPath
        self.previousContent = previousContent
        self.timestamp = timestamp
        self.issueId = issueId
        self.batchId = batchId
    }
}

// MARK: - Display Helpers

extension WorkFileOperationType {
    /// SF Symbol for this operation type
    public var iconName: String {
        switch self {
        case .create: return "doc.badge.plus"
        case .write: return "pencil"
        case .move: return "arrow.right"
        case .copy: return "doc.on.doc"
        case .delete: return "trash"
        case .dirCreate: return "folder.badge.plus"
        }
    }

    /// Human-readable description
    public var displayName: String {
        switch self {
        case .create: return "Created"
        case .write: return "Modified"
        case .move: return "Moved"
        case .copy: return "Copied"
        case .delete: return "Deleted"
        case .dirCreate: return "Created folder"
        }
    }
}

extension WorkFileOperation {
    /// Display filename (last path component)
    public var filename: String {
        (path as NSString).lastPathComponent
    }

    /// Display path for destination (for move/copy)
    public var destinationFilename: String? {
        destinationPath.map { ($0 as NSString).lastPathComponent }
    }
}
