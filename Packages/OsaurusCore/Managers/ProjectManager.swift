//
//  ProjectManager.swift
//  osaurus
//
//  Manages project lifecycle - loading, creating, updating, deleting
//

import Combine
import Foundation

extension Notification.Name {
    /// Posted after a project is created, updated, or deleted.
    /// `userInfo["projectId"]` is the affected project's UUID.
    static let projectsChanged = Notification.Name("projectsChanged")
}

/// Manages all projects. Sessions reference projects by `projectId`;
/// membership itself lives on `ChatSessionData`.
@MainActor
public final class ProjectManager: ObservableObject {
    public static let shared = ProjectManager()

    @Published public private(set) var projects: [Project] = []

    /// One-shot request to reveal the sidebar's Projects tab — set by the
    /// "What's New" projects CTA. `ChatSessionSidebar` observes this, switches
    /// its lens to Projects, and resets it to false.
    @Published public var pendingRevealProjectsTab: Bool = false

    private init() {
        projects = ProjectStore.loadAll()
    }

    public func project(for id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    @discardableResult
    public func create(name: String) -> Project {
        let project = Project(name: name)
        ProjectStore.save(project)
        projects = ProjectStore.loadAll()
        notify(project.id)
        return project
    }

    public func update(_ project: Project) {
        var updated = project
        updated.updatedAt = Date()
        ProjectStore.save(updated)
        projects = ProjectStore.loadAll()
        notify(project.id)
    }

    /// Mint a security-scoped bookmark for `url` and store it as the
    /// project's working folder. Minting does synchronous IPC that can stall
    /// for seconds, so it runs off the main actor (same as
    /// `ChatFolderState.setFolder`) to stay clear of the app-hang watchdog.
    /// Returns the display path on success, nil if the bookmark could not be
    /// created or the project no longer exists.
    @discardableResult
    public func setFolder(_ url: URL, for projectId: UUID) async -> String? {
        let bookmark: Data
        do {
            bookmark = try await Task.detached(priority: .userInitiated) {
                try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }.value
        } catch {
            return nil
        }
        guard var project = project(for: projectId) else { return nil }
        let path = url.standardizedFileURL.path
        project.folderBookmark = bookmark
        project.folderPath = path
        update(project)
        return path
    }

    /// Remove the project's working folder. New chats in the project fall
    /// back to starting folder-less, as before.
    public func clearFolder(for projectId: UUID) {
        guard var project = project(for: projectId),
            project.folderBookmark != nil || project.folderPath != nil
        else { return }
        project.folderBookmark = nil
        project.folderPath = nil
        update(project)
    }

    /// Deletes the project record. Callers are responsible for clearing
    /// `projectId` on member sessions (see `ChatSessionsManager`).
    public func delete(id: UUID) {
        guard ProjectStore.delete(id: id) else { return }
        projects = ProjectStore.loadAll()
        notify(id)
    }

    private func notify(_ id: UUID) {
        NotificationCenter.default.post(
            name: .projectsChanged, object: nil, userInfo: ["projectId": id])
    }
}
