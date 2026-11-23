//
//  WorkflowConnectionActions.swift
//  osaurus
//
//  Renewing a workflow connection in place, and what the Workflows
//  window's Connections sheet lists. Vault → Accounts, that sheet, and
//  workflow setup all sign in again through here, so a renewed sign-in
//  keeps its id and every workflow and agent bound to it follows.
//

import Foundation

@MainActor
enum WorkflowConnectionActions {
    enum Failure: Error, LocalizedError {
        case notSignIn

        var errorDescription: String? {
            L("This connection is a pasted value. Enter the value again instead.")
        }
    }

    /// A pasted key or token is renewed by entering it again; a sign-in
    /// goes through the browser.
    static func pastesValue(_ connection: WorkflowConnection) -> Bool { connection.kind == .value }

    /// Refreshes when a refresh token is stored. Otherwise, or when the
    /// service refuses the refresh, signs in again in the browser into the
    /// same connection.
    static func signInAgain(_ connection: WorkflowConnection, clientSecret: String? = nil) async throws {
        guard let spec = connection.oauth2, connection.kind == .oauth2 else { throw Failure.notSignIn }
        if connection.canRefresh, !connection.needsSignIn() {
            do {
                let tokens = try await OAuth2ConnectionFlow.refresh(connection)
                OAuth2ConnectionFlow.store(tokens, in: connection)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
            }
        }
        _ = try await OAuth2ConnectionFlow.signIn(
            spec: spec, name: connection.name, clientSecret: clientSecret, replacing: connection)
    }

    /// Saves a newly pasted value into the connection. False when the
    /// Keychain refused it.
    static func replaceValue(_ value: String, in id: UUID) -> Bool {
        WorkflowSecretsKeychain.save(value, account: WorkflowSecretsKeychain.connectionAccount(id: id, field: "value"))
    }
}

/// The connections installed workflows sign in with, and the connection
/// secrets setup has not filled yet.
struct WorkflowConnectionOverview: Equatable {
    struct Entry: Identifiable, Equatable {
        enum Status: Equatable {
            case ready
            case signInExpired
            case noValue
        }

        let connection: WorkflowConnection
        let status: Status
        /// Names of the installed workflows bound to it.
        let workflows: [String]

        var id: UUID { connection.id }
    }

    /// A workflow's connection secret with nothing usable bound to it.
    struct Need: Identifiable, Equatable {
        let workflowID: UUID
        let workflowName: String
        let secret: SecretRequirement

        var id: String { "\(workflowID.uuidString):\(secret.key)" }
    }

    var entries: [Entry]
    var needs: [Need]

    /// `hasValue` and `isSetUp` (scope, key) read the Keychain; tests pass
    /// stand-ins.
    static func build(
        connections: [WorkflowConnection], workflows: [InstalledWorkflow],
        hasValue: (WorkflowConnection) -> Bool, isSetUp: (UUID, String) -> Bool
    ) -> WorkflowConnectionOverview {
        let known = Set(connections.map(\.id))
        let entries = connections.map { connection in
            let binding = connection.binding
            let users = workflows.filter { $0.bindings.secrets.values.contains(binding) }.map(\.name)
            let status: Entry.Status =
                connection.needsSignIn() ? .signInExpired : hasValue(connection) ? .ready : .noValue
            return Entry(connection: connection, status: status, workflows: users)
        }
        var needs: [Need] = []
        for workflow in workflows {
            for secret in workflow.template.requirements.secrets where secret.isConnection {
                let bound = workflow.bindings.secrets[secret.key]
                if let id = bound.flatMap(WorkflowSecretsKeychain.connectionID(of:)) {
                    if known.contains(id) { continue }
                } else if isSetUp(workflow.id, secret.key) {
                    continue
                }
                needs.append(Need(workflowID: workflow.id, workflowName: workflow.name, secret: secret))
            }
        }
        return WorkflowConnectionOverview(entries: entries, needs: needs)
    }
}
