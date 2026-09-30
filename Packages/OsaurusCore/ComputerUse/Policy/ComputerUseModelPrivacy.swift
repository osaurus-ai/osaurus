//
//  ComputerUseModelPrivacy.swift
//  OsaurusCore -- Computer Use
//
//  Privacy boundary for the nested computer-use model loop. The loop prompt
//  carries AX-derived screen state (`AgentView`) and, after escalation, may
//  carry screenshots. Until there is a consented, redacted remote projection
//  for that whole prompt, the sub-agent itself must run on-device.
//

import Foundation

enum ComputerUseModelPrivacy {
    typealias InstalledModelResolver = @Sendable (String) -> Bool

    static func isOnDeviceModel(
        _ modelId: String,
        installedModelResolver: InstalledModelResolver = {
            ModelManager.findInstalledModel(named: $0) != nil
        }
    ) -> Bool {
        let id = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return false }
        if id.caseInsensitiveCompare("default") == .orderedSame { return true }
        if id.caseInsensitiveCompare(FoundationModelService.serviceId) == .orderedSame { return true }
        return installedModelResolver(id)
    }

    static func remoteModelFailureEnvelope(modelId: String, tool: String) -> String {
        ToolEnvelope.failure(
            kind: .unavailable,
            message: remoteModelFailureMessage(modelId: modelId),
            tool: tool,
            retryable: false
        )
    }

    static func remoteModelFailureMessage(modelId: String) -> String {
        "Computer Use is local-only for screen privacy. The selected model '\(modelId)' appears to be remote, and the computer-use sub-agent would need AX-derived screen state to decide each step. "
            + "Select an on-device Foundation or installed MLX model, then try again."
    }
}
