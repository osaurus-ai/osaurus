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
