//
//  WorkflowVisibility.swift
//  osaurus
//
//  Who can see a workflow published to store.osaurus.ai. The owner
//  chooses; the registry enforces. Separate from moderation (a taken-down
//  workflow is gone whatever its visibility).
//

import Foundation

public enum WorkflowVisibility: String, Codable, CaseIterable, Sendable {
    /// Listed and searchable on the registry and the author's page.
    case `public`
    /// Reachable by link only; left out of lists and search.
    case hidden
    /// Reachable by link, and every read needs the owner's password.
    case password
    /// Read only by members of the workspaces it's shared with, each read
    /// proved with a router workspace attestation.
    case workspace

    /// The registry's password bounds (`MIN_PASSWORD_LENGTH` / `MAX_PASSWORD_LENGTH`).
    public static let passwordLength = 6 ... 128

    /// The registry's `MAX_SHARED_WORKSPACES`.
    public static let maxWorkspaces = 20

    public var title: String {
        switch self {
        case .public: return L("Public")
        case .hidden: return L("Unlisted")
        case .password: return L("Password")
        case .workspace: return L("Workspace")
        }
    }

    public var detail: String {
        switch self {
        case .public: return L("Listed on store.osaurus.ai and your author page.")
        case .hidden: return L("Only people with the link.")
        case .password: return L("Only people with the link and the password.")
        case .workspace: return L("Only members of the workspaces you choose.")
        }
    }

    public var symbol: String {
        switch self {
        case .public: return "globe"
        case .hidden: return "link"
        case .password: return "lock"
        case .workspace: return "person.2"
        }
    }

    public static func isValidPassword(_ password: String) -> Bool {
        passwordLength.contains(password.count)
    }

    public static func isValidWorkspaceSelection(_ ids: [String]) -> Bool {
        (1 ... maxWorkspaces).contains(Set(ids).count)
    }
}
