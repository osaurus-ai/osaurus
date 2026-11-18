//
//  TemplateCascadePlan.swift
//  osaurus
//
//  What publishing an agent template does for the workflows it bundles.
//  Yours (no author address, or this Osaurus ID's) get their own page with
//  the agent's visibility, unless one is already live at that version.
//  Someone else's are never republished, even when an edit dropped their
//  signature and kept their address: the registry links the agent to
//  the original author's page when the bundled copy is exactly one of
//  their published versions. The registry links every one of these to the
//  agent; this plan is only what this Mac publishes first.
//

import Foundation

public struct TemplateCascadePlan: Equatable, Sendable {

    /// Why a workflow of yours stays inside the agent only.
    public enum Reason: Equatable, Sendable {
        /// The agent is password-protected; its workflows don't get pages
        /// anyone could find without the password.
        case passwordProtected
        /// The agent is shared with workspaces; the registry never links a
        /// workspace listing, so its workflows travel inside it.
        case workspaceOnly
        /// A built-in Osaurus workflow isn't yours to sign.
        case builtIn
        /// You took its page down; publishing the agent doesn't undo that.
        case takenDown
        /// The Osaurus team removed its page.
        case removedByAdmin
        /// Publishing its own page was turned off for this publish.
        case turnedOff
    }

    public enum State: Equatable, Sendable {
        /// Live at this version or newer; the agent links to it.
        case alreadyPublished(WorkflowRegistryRecord)
        /// Gets its own page (or a new version of it) before the agent.
        case willPublish
        /// Carries another Osaurus ID's address (signed or not); linked to
        /// their page when they published this exact version.
        case linkedToAuthor(address: String)
        /// Carries an author address while this Osaurus ID's isn't known yet
        /// (before the key is read); publishing decides between the two above.
        case checksOnPublish(address: String)
        case bundledOnly(Reason)
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let template: Template
        public let state: State
        /// This Mac's record for the workflow, when it has one.
        public let record: WorkflowRegistryRecord?

        public var id: UUID { template.id }
    }

    public let rows: [Row]
    /// The visibility the workflows that publish get; nil when none can.
    public let visibility: WorkflowVisibility?

    public var toPublish: [Template] {
        rows.compactMap { $0.state == .willPublish ? $0.template : nil }
    }

    public var isEmpty: Bool { rows.isEmpty }

    /// Whether publishing may give any workflow its own page.
    public var mayPublish: Bool {
        rows.contains {
            switch $0.state {
            case .willPublish, .checksOnPublish: return true
            default: return false
            }
        }
    }

    /// A bundled workflow takes the agent's visibility: Public and Unlisted
    /// carry over; a password-protected or workspace agent keeps them
    /// bundled only.
    public static func inheritedVisibility(_ agent: WorkflowVisibility) -> WorkflowVisibility? {
        switch agent {
        case .public: return .public
        case .hidden: return .hidden
        case .password, .workspace: return nil
        }
    }

    /// The workflow pages published with an agent that follow a change to
    /// its visibility: live, not password-protected or workspace-shared on
    /// their own, and not already at what they inherit. None when the agent
    /// gets a password or goes to workspaces.
    public static func visibilityFollowers(
        _ published: [WorkflowRegistryRecord], agentVisibility: WorkflowVisibility
    ) -> [WorkflowRegistryRecord] {
        guard let inherited = inheritedVisibility(agentVisibility) else { return [] }
        return published.filter {
            $0.isLive && $0.visibility != .password && $0.visibility != .workspace && $0.visibility != inherited
        }
    }

    /// `ownAddress` is this Osaurus ID's address when known; without it a
    /// workflow with an author address is yours when this Mac published it,
    /// and otherwise `checksOnPublish`.
    public static func make(
        template: Template,
        visibility: WorkflowVisibility,
        ownAddress: String?,
        publishWorkflows: Bool = true,
        record: (UUID) -> WorkflowRegistryRecord?,
        isBuiltIn: (UUID) -> Bool
    ) -> TemplateCascadePlan {
        let inherited = inheritedVisibility(visibility)
        let own = ownAddress?.lowercased()
        let rows = template.bundled.map { workflow -> Row in
            let existing = record(workflow.id)
            if let author = workflow.author?.address?.lowercased(), !author.isEmpty,
                author != own, existing?.address.lowercased() != author
            {
                let state: State = own == nil ? .checksOnPublish(address: author) : .linkedToAuthor(address: author)
                return Row(template: workflow, state: state, record: existing)
            }
            let state: State
            if isBuiltIn(workflow.id) {
                state = .bundledOnly(.builtIn)
            } else if let existing, existing.removedByAdmin {
                state = .bundledOnly(.removedByAdmin)
            } else if let existing, existing.takenDown {
                state = .bundledOnly(.takenDown)
            } else if let existing, (existing.registryLatestVersion ?? existing.version) >= workflow.version {
                state = .alreadyPublished(existing)
            } else if inherited == nil {
                state = .bundledOnly(visibility == .workspace ? .workspaceOnly : .passwordProtected)
            } else if !publishWorkflows {
                state = .bundledOnly(.turnedOff)
            } else {
                state = .willPublish
            }
            return Row(template: workflow, state: state, record: existing)
        }
        return TemplateCascadePlan(rows: rows, visibility: inherited)
    }
}

/// What publishing an agent did for one bundled workflow.
public struct TemplateCascadeResult: Equatable, Sendable, Identifiable {
    public enum Status: Equatable, Sendable {
        /// Published (or a new version) with the agent.
        case published(WorkflowRegistryRecord)
        case alreadyPublished(WorkflowRegistryRecord)
        case linkedToAuthor(address: String)
        case bundledOnly(TemplateCascadePlan.Reason)
        /// Its own page didn't publish; the agent still carries it.
        case failed(String)
    }

    public let templateID: UUID
    public let name: String
    public let status: Status

    public var id: UUID { templateID }

    /// The page the agent links to, when there is one on this Mac's records.
    public var record: WorkflowRegistryRecord? {
        switch status {
        case .published(let r), .alreadyPublished(let r): return r
        default: return nil
        }
    }
}
