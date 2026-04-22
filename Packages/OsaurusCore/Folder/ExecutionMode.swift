//
//  ExecutionMode.swift
//  osaurus
//
//  First-class execution mode for work sessions.
//

import Foundation

public enum ExecutionMode: Sendable {
    case hostFolder(FolderContext)
    case sandbox
    case none

    public var folderContext: FolderContext? {
        guard case .hostFolder(let context) = self else { return nil }
        return context
    }

    public var usesHostFolderTools: Bool {
        if case .hostFolder = self {
            return true
        }
        return false
    }

    public var usesSandboxTools: Bool {
        if case .sandbox = self {
            return true
        }
        return false
    }
}
