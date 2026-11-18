//
//  WorkflowExecutionContext.swift
//  osaurus
//
//  The execution context every node attempt runs under, resolved from the
//  run instead of inherited from whichever task started it. Tools see the
//  caller agent, its chat session, and the run's working folder; Insights
//  rows emitted inside the node carry the run and node; approvals given
//  with "Allow for This Task" last for the whole run; and a caller with no
//  window (HTTP, MCP) gets the same typed approval refusals it gets in chat.
//

import Foundation

enum WorkflowExecutionContext {

    /// Who owns the models the node's own model calls load. Only those
    /// calls read it; the chat-wide `currentSessionSource` stays unbound
    /// so tool and prompt resolution are unchanged.
    @TaskLocal static var residencySource: SessionSource?

    /// Runs `body` with the node's context bound. `grantedTools` are the
    /// tools the node itself lists (see `workflowGrantedToolNames`).
    static func bind<T>(
        _ context: WorkflowNodeContext, grantedTools: Set<String>? = nil, _ body: () async throws -> T
    ) async throws -> T {
        let caller = context.caller
        let granted = grantedTools ?? Set(context.node.calledTools.map(\.name))
        return try await $residencySource.withValue(caller.residencySource) {
            try await ChatExecutionContext.$currentTaskId.withValue(caller.runTaskId(runID: context.runID)) {
                try await bindChatContext(context, caller: caller, granted: granted, body)
            }
        }
    }

    // Split in two: one closure nesting every binding is too much for the type checker.
    private static func bindChatContext<T>(
        _ context: WorkflowNodeContext, caller: WorkflowCaller, granted: Set<String>, _ body: () async throws -> T
    ) async throws -> T {
        try await ChatExecutionContext.$currentWorkflowRunId.withValue(context.runID) {
            try await ChatExecutionContext.$currentWorkflowNodeId.withValue(context.node.id) {
                try await ChatExecutionContext.$currentWorkflowStepReason.withValue(context.node.approvalReason) {
                    try await ChatExecutionContext.$currentAgentId.withValue(caller.agentID) {
                        try await ChatExecutionContext.$usesSharedKeysOnly.withValue(caller.credentialAgentID == nil) {
                            try await ChatExecutionContext.$currentSessionId.withValue(caller.sessionID) {
                                try await ChatExecutionContext.$currentToolCallId.withValue(caller.toolCallID) {
                                    try await bindRunScope(context, caller: caller, granted: granted, body)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func bindRunScope<T>(
        _ context: WorkflowNodeContext, caller: WorkflowCaller, granted: Set<String>, _ body: () async throws -> T
    ) async throws -> T {
        let grantedPaths = [context.workspace] + context.grantedPaths
        let writableRoots = context.writableRoots.map { [context.workspace] + $0 }
        return try await ChatExecutionContext.$currentFolderRoot.withValue(context.folderRoot) {
            try await ChatExecutionContext.$toolPermissionRunScope.withValue(context.permissionScope) {
                try await ChatExecutionContext.$isExternalSurface.withValue(caller.isExternalSurface) {
                    try await ChatExecutionContext.$hasRemoteReviewer.withValue(caller.hasRemoteReviewer) {
                        try await ChatExecutionContext.$isUnattendedDispatch.withValue(caller.isUnattendedDispatch) {
                            try await bindWorkflowAccess(context, granted: granted, grantedPaths, writableRoots, body)
                        }
                    }
                }
            }
        }
    }

    private static func bindWorkflowAccess<T>(
        _ context: WorkflowNodeContext, granted: Set<String>, _ grantedPaths: [URL], _ writableRoots: [URL]?,
        _ body: () async throws -> T
    ) async throws -> T {
        try await ChatExecutionContext.$workflowGrantedToolNames.withValue(granted) {
            try await ChatExecutionContext.$workflowSandbox.withValue(context.sandbox) {
                try await ChatExecutionContext.$workflowGrantedPaths.withValue(grantedPaths) {
                    try await ChatExecutionContext.$workflowWritableRoots.withValue(writableRoots) {
                        try await ChatExecutionContext.$workflowHostFiles.withValue(context.hostFiles) {
                            try await body()
                        }
                    }
                }
            }
        }
    }
}

extension WorkflowNode {
    /// What the step is for, in the author's words: its intent, else its name.
    var approvalReason: String? {
        for candidate in [intent, name] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

extension WorkflowCaller {
    /// The task a run's steps belong to (`WorkflowTaskRecorder`): the
    /// automation's task, else the run's own. Test runs are not tasks.
    func runTaskId(runID: UUID) -> UUID? {
        if let taskId { return taskId }
        return kind == .test ? nil : runID
    }

    /// The surface a run's model loads belong to. Its model steps load
    /// under this owner and its local media steps hand off under it, so a
    /// run can swap out the model it loaded itself and nothing else's.
    var residencySource: SessionSource {
        if isExternalSurface { return .http }
        if kind == .event { return channelReply != nil ? .channel : .automation }
        if isUnattendedDispatch { return .schedule }
        return .chat
    }
}
