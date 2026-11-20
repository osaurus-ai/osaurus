//
//  SupportReportExtras.swift
//  osaurus
//
//  The "Share extra details" block of a report: metadata about the one item
//  the user picked, read from this Mac. Same rule as the diagnostics bundle:
//  ids, names, counts, sizes, statuses and timings, never prompts, inputs,
//  outputs or chat text.
//

import Foundation

enum SupportReportExtras {
    /// Workflow runs included, newest first.
    static let workflowRunLimit = 5

    /// Extras for the draft's category and pick, read from the live stores.
    /// Nil when the switch is off, the category has none, or the picked item
    /// is gone.
    @MainActor
    static func current(for draft: SupportReportDraft) -> JSONValue? {
        guard draft.sendsExtras, let category = draft.category else { return nil }
        switch category {
        case .bug:
            return nil
        case .cloud:
            let providers = RemoteProviderManager.shared
            return cloud(
                enabled: providers.isOsaurusRouterEnabled,
                offline: providers.isOffline,
                hasAccount: OsaurusIdentity.existsCached(),
                state: providers.providerStates[RemoteProviderManager.osaurusRouterProviderId],
                pickedModel: draft.cloudModel?.id)
        case .agent:
            guard let id = draft.agent.flatMap({ UUID(uuidString: $0.id) }),
                let agent = AgentManager.shared.agent(for: id)
            else { return nil }
            return self.agent(agent)
        case .workflow:
            guard let id = draft.workflow.flatMap({ UUID(uuidString: $0.id) }) else { return nil }
            return workflow(runs: WorkflowRunStore.shared.runs(workflowID: id, limit: workflowRunLimit))
        case .ios:
            let defaults = UserDefaults.standard
            return pairing(
                device: MobilePairingService.shared.pairedDevice,
                reachFromAnywhere: defaults.bool(forKey: MobilePairingService.reachAnywhereDefaultsKey),
                keepMacAwake: defaults.bool(forKey: MobilePairingService.keepAwakeDefaultsKey))
        case .store:
            guard draft.storeDirection == .publishing,
                let id = draft.storeListing.flatMap({ UUID(uuidString: $0.id) }),
                let record = WorkflowRegistryRecordStore.shared.record(for: id)
            else { return nil }
            return listing(record)
        case .model:
            guard let id = draft.model?.id,
                let model = ModelManager.shared.availableModels.first(where: { $0.id == id })
            else { return nil }
            return self.model(model)
        }
    }

    /// Whether the connection is up and what it lists. The last error's text
    /// is left out like every other error string; only that one happened.
    static func cloud(
        enabled: Bool,
        offline: Bool,
        hasAccount: Bool,
        state: RemoteProviderState?,
        pickedModel: String?
    ) -> JSONValue {
        var object: [String: JSONValue] = [
            "enabled": .bool(enabled),
            "offline": .bool(offline),
            "has_account": .bool(hasAccount),
            "connected": .bool(state?.isConnected ?? false),
            "connecting": .bool(state?.isConnecting ?? false),
            "last_attempt_failed": .bool(state?.lastError != nil),
            "model_count": .number(Double(state?.modelCount ?? 0)),
        ]
        if let state {
            if state.lastError != nil { object["failure_transient"] = .bool(state.lastFailureWasTransient) }
            if state.requiresAuth { object["requires_sign_in"] = .bool(true) }
            if let connected = state.lastConnectedAt { object["last_connected_at"] = .string(iso(connected)) }
        }
        if let pickedModel {
            object["picked_model_listed"] = .bool(state?.discoveredModels.contains(pickedModel) ?? false)
        }
        return .object(["osaurus_cloud": .object(object)])
    }

    static func agent(_ agent: Agent) -> JSONValue {
        var object: [String: JSONValue] = [
            "built_in": .bool(agent.isBuiltIn),
            "model_locked": .bool(agent.modelLocked ?? false),
            "has_instructions": .bool(
                !agent.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
        ]
        if let model = agent.defaultModel { object["default_model"] = .string(model) }
        if let temperature = agent.temperature { object["temperature"] = .number(Double(temperature)) }
        if let maxTokens = agent.maxTokens { object["max_tokens"] = .number(Double(maxTokens)) }
        return .object(["agent": .object(object)])
    }

    static func workflow(runs: [WorkflowRun]) -> JSONValue {
        let rows: [JSONValue] = runs.prefix(workflowRunLimit).map { run in
            var row: [String: JSONValue] = [
                "status": .string(run.status.rawValue),
                "started_at": .string(iso(run.startedAt)),
                "steps": .number(Double(run.nodes.count)),
            ]
            if let finished = run.finishedAt {
                row["duration_seconds"] = .number((finished.timeIntervalSince(run.startedAt) * 10).rounded() / 10)
            }
            if let error = run.error {
                if let step = error.nodeID { row["failed_step"] = .string(step) }
                if let failure = error.failure {
                    row["failure_kind"] = .string(failure.kind)
                    row["failure_type"] = .string(failure.errorType)
                    row["fix_in"] = .string(failure.fixIn.rawValue)
                    if let tool = failure.tool { row["tool"] = .string(tool) }
                }
            }
            return .object(row)
        }
        return .object(["workflow_runs": .array(rows)])
    }

    static func pairing(device: PairedMobileDevice?, reachFromAnywhere: Bool, keepMacAwake: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "paired": .bool(device != nil),
            "reach_from_anywhere": .bool(reachFromAnywhere),
            "keep_mac_awake": .bool(keepMacAwake),
        ]
        if let device {
            object["paired_at"] = .string(iso(device.pairedAt))
            if let expires = device.keyExpiresAt { object["key_expires_at"] = .string(iso(expires)) }
            if device.isSimulator == true { object["simulator"] = .bool(true) }
        }
        return .object(["pairing": .object(object)])
    }

    static func listing(_ record: WorkflowRegistryRecord) -> JSONValue {
        var object: [String: JSONValue] = [
            "registry_id": .string(record.registryID),
            "slug": .string(record.slug),
            "kind": .string(record.kind.rawValue),
            "version": .number(Double(record.version)),
            "visibility": .string(record.visibility.rawValue),
            "taken_down": .bool(record.takenDown),
            "removed_by_admin": .bool(record.removedByAdmin),
        ]
        if let latest = record.registryLatestVersion { object["registry_latest_version"] = .number(Double(latest)) }
        return .object(["listing": .object(object)])
    }

    static func model(_ model: MLXModel) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(model.id)]
        if let type = model.modelType { object["model_type"] = .string(type) }
        if let bytes = model.weightSizeBytes { object["weight_bytes"] = .number(Double(bytes)) }
        if let bytes = model.downloadSizeBytes { object["download_bytes"] = .number(Double(bytes)) }
        return .object(["model": .object(object)])
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
