//
//  WorkflowFolderGrantCoordinator.swift
//  osaurus
//
//  A tool step that names a path outside every folder its run may use
//  fails with `needs_folder_grant`. Instead of failing the run, the step
//  asks the person whether the workflow may use that folder: once (this
//  run), always (saved on the install's bindings), or not at all. The
//  question is an ordinary `PendingDialog`, so it shows wherever workflow
//  forms show and follows their cancel and timeout rules.
//

import Foundation

public enum WorkflowFolderGrantDecision: String, Sendable, CaseIterable {
    case allowOnce = "allow_once"
    case allowAlways = "allow_always"
    case deny

    /// The option the card shows for this decision.
    var label: String {
        switch self {
        case .allowOnce: return L("Allow for this run")
        case .allowAlways: return L("Always allow")
        case .deny: return L("Don't allow")
        }
    }

    /// The card's choice, by label or raw value (relay clients send either).
    init?(answer: JSONValue?) {
        guard let text = answer?.stringValue else { return nil }
        guard let match = Self.allCases.first(where: { $0.rawValue == text || $0.label == text }) else { return nil }
        self = match
    }
}

/// Asks the person to allow a folder for one run, to read from it or to
/// save in it. Returns their decision.
public typealias WorkflowFolderGrantRequest =
    @Sendable (_ path: String, _ access: FolderRequirement.Access) async throws -> WorkflowFolderGrantDecision

enum WorkflowFolderGrant {
    /// Failure-envelope key carrying the absolute path a step tried to use.
    static let needsGrantKey = "needs_folder_grant"
    /// Failure-envelope key: `read` or `write`, what the step tried to do.
    static let accessKey = "folder_grant_access"
    /// Failure-envelope key carrying the folder whose files the person did
    /// not allow the run to replace.
    static let replaceDeniedKey = "replace_denied"

    /// The path a failure envelope asks to be allowed, if any.
    static func requestedPath(in envelope: String) -> String? {
        guard let object = JSONValue.parse(envelope)?.objectValue,
            let path = object[needsGrantKey]?.stringValue, path.hasPrefix("/")
        else { return nil }
        return path
    }

    /// What the step tried to do at the requested path. A grant asked by an
    /// older envelope without the key covers reading and saving, as before.
    static func requestedAccess(in envelope: String) -> FolderRequirement.Access {
        JSONValue.parse(envelope)?.objectValue?[accessKey]?.stringValue.flatMap(FolderRequirement.Access.init)
            ?? .write
    }

    /// Whether a failure envelope is a declined replace.
    static func isReplaceDenied(_ envelope: String) -> Bool {
        JSONValue.parse(envelope)?.objectValue?[replaceDeniedKey]?.stringValue != nil
    }
}

enum WorkflowFolderGrantCoordinator {
    static let decisionKey = "decision"

    static func dialog(
        runID: UUID, workflowID: UUID, workflowName: String, node: WorkflowNode, path: String,
        access: FolderRequirement.Access = .write, caller: WorkflowCaller
    ) -> PendingDialog {
        let folder = FolderRequirement.grantRoot(for: path)
        let folderName = WorkflowAccessScope.displayName(folder)
        let title: String
        let message: String
        switch access {
        case .read:
            title = L("Allow \(workflowName) to read \(folderName)?")
            message = L(
                "The step “\(node.name)” wants to read \(path), which is outside the folders this workflow may use. Allowing it lets the workflow read files in \(folder.path). It can't save or change anything there."
            )
        case .write:
            title = L("Allow \(workflowName) to save in \(folderName)?")
            message = L(
                "The step “\(node.name)” wants to save \(path), which is outside the places this workflow saves to. Allowing it lets the workflow read and save files in \(folder.path)."
            )
        }
        return PendingDialog(
            id: UUID(), runID: runID, workflowID: workflowID, workflowName: workflowName,
            nodeID: "\(node.id)#folder-grant",
            title: title,
            message: message,
            fields: [
                DialogField(
                    key: decisionKey, label: L("Access"), type: .choice, required: true,
                    defaultValue: .string(WorkflowFolderGrantDecision.allowOnce.label),
                    options: WorkflowFolderGrantDecision.allCases.map(\.label),
                    help: L("Always allow saves the folder with this workflow. Remove it from the workflow's details."))
            ],
            prefill: [decisionKey: .string(WorkflowFolderGrantDecision.allowOnce.label)],
            caller: caller, createdAt: Date())
    }

    /// The card asking whether the run may replace files that already exist
    /// in `folder`, starting with `file`.
    static func replaceDialog(
        runID: UUID, workflowID: UUID, workflowName: String, node: WorkflowNode, folder: URL, file: URL,
        caller: WorkflowCaller
    ) -> PendingDialog {
        let folderName = WorkflowAccessScope.displayName(folder)
        return PendingDialog(
            id: UUID(), runID: runID, workflowID: workflowID, workflowName: workflowName,
            nodeID: "\(node.id)#replace-grant",
            title: L("Replace files in \(folderName)?"),
            message: L(
                "The step “\(node.name)” wants to replace \(file.lastPathComponent), which is already in \(folder.path). Allowing it lets this run replace existing files in that folder."
            ),
            fields: [
                DialogField(
                    key: decisionKey, label: L("Replace"), type: .choice, required: true,
                    defaultValue: .string(WorkflowFolderGrantDecision.allowOnce.label),
                    options: WorkflowFolderGrantDecision.allCases.map(\.label),
                    help: L("Always allow saves this with the workflow. Remove it from the workflow's details."))
            ],
            prefill: [decisionKey: .string(WorkflowFolderGrantDecision.allowOnce.label)],
            caller: caller, createdAt: Date())
    }

    /// Shows the card and waits for the answer. Dismissing the card counts
    /// as not allowing it; cancelling the run propagates.
    @MainActor
    static func request(_ dialog: PendingDialog) async throws -> WorkflowFolderGrantDecision {
        do {
            let answers = try await DialogCoordinator.shared.present(dialog)
            return WorkflowFolderGrantDecision(answer: answers[decisionKey]) ?? .deny
        } catch WorkflowNodeError.dialogDismissed {
            return .deny
        }
    }

    /// Nobody can answer a card for this caller.
    static func canAsk(_ caller: WorkflowCaller) -> Bool {
        !caller.isHeadless && !caller.isUnattendedDispatch
    }
}
