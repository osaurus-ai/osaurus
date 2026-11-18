//
//  WorkflowTrust.swift
//  osaurus
//
//  What a person checks instead of reading a graph: per-step risk and cost
//  badges (hosts reached, files written, shell or browser use, cloud or
//  local model, time and tokens seen in past runs), the test evidence a
//  save stands on, and a plain-language account of a finished run.
//

import Foundation

// MARK: - Step badges

/// One fact about a step worth a glance before trusting it.
public struct WorkflowStepBadge: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        case network, secrets, files, shell, browser, mac, media, cloudModel, localModel, agentic, asksUser, waits,
            subworkflow, fanOut, cost, storesData, replies, delegates, yourMac
    }
    public enum Tone: String, Sendable { case neutral, caution, risky }

    public var kind: Kind
    /// Short, as shown on the card: "Reaches api.github.com".
    public var label: String
    /// The full list behind the label, for a tooltip.
    public var detail: String?
    public var tone: Tone

    public var id: String { "\(kind.rawValue):\(label)" }

    public var systemImage: String {
        switch kind {
        case .network: return "network"
        case .secrets: return "key"
        case .files: return "doc.badge.plus"
        case .shell: return "terminal"
        case .browser: return "safari"
        case .mac: return "macwindow"
        case .media: return "photo"
        case .cloudModel: return "cloud"
        case .localModel: return "desktopcomputer"
        case .agentic: return "wand.and.stars"
        case .asksUser: return "person.crop.circle.badge.questionmark"
        case .waits: return "clock"
        case .subworkflow: return "flowchart"
        case .fanOut: return "square.stack.3d.down.right"
        case .cost: return "gauge"
        case .storesData: return "tray.full"
        case .replies: return "arrowshape.turn.up.left"
        case .delegates: return "person.2"
        case .yourMac: return WorkflowAccessScope.Place.mac.systemImage
        }
    }
}

/// Where a model runs, for the cloud/local badge.
public enum WorkflowModelLocality: String, Codable, Equatable, Sendable {
    case local, cloud, unbound
}

public enum WorkflowStepRisk {
    /// Tools that run programs on this Mac or in the workflow's sandbox.
    static let shellTools: Set<String> = ["shell_run", "applescript"]
    /// Tools that drive a browser.
    static let browserTools: Set<String> = ["browser_use", "web_browse", "web_fetch"]
    /// Tools that control or read the Mac beyond files.
    static let macTools: Set<String> = ["computer_use", "mac_query", "osaurus_config", "osaurus_import"]
    /// Tools that write or move files.
    static let fileWriteTools: Set<String> = [
        "file_write", "file_edit", "file_copy", "file_move", "file_delete", "share_artifact", "file_create",
    ]
    static let mediaTools: Set<String> = ["image", "video", "image_generate", "video_generate"]
    /// Tools that search or call the web.
    static let webTools: Set<String> = ["web_search", "search_and_extract", "http_request"]

    /// Averages from past runs of the same step, when there are any.
    public struct History: Equatable, Sendable {
        public var runs: Int
        public var averageMs: Int?
        public var averageTokens: Int?
        public var failures: Int

        public init(runs: Int, averageMs: Int?, averageTokens: Int?, failures: Int) {
            self.runs = runs
            self.averageMs = averageMs
            self.averageTokens = averageTokens
            self.failures = failures
        }
    }

    /// The badges for `node`. `locality` answers for a model slot; nil
    /// means the slot is not bound yet.
    public static func badges(
        for node: WorkflowNode, in definition: WorkflowDefinition, locality: (String) -> WorkflowModelLocality,
        history: History? = nil
    ) -> [WorkflowStepBadge] {
        var out: [WorkflowStepBadge] = []
        func add(_ kind: WorkflowStepBadge.Kind, _ label: String, detail: String? = nil, tone: WorkflowStepBadge.Tone) {
            out.append(WorkflowStepBadge(kind: kind, label: label, detail: detail, tone: tone))
        }
        func hosts(_ list: [String]) {
            let hosts = list.map { $0.lowercased() }.filter { !$0.isEmpty }
            guard !hosts.isEmpty else { return }
            let label = hosts.count == 1 ? L("Reaches \(hosts[0])") : L("Reaches \(hosts[0]) +\(hosts.count - 1)")
            add(.network, label, detail: hosts.joined(separator: ", "), tone: .caution)
        }
        func secrets(_ keys: [String]) {
            let keys = keys.filter { !$0.isEmpty }
            guard !keys.isEmpty else { return }
            add(
                .secrets, keys.count == 1 ? L("Uses secret \(keys[0])") : L("Uses \(keys.count) secrets"),
                detail: keys.joined(separator: ", "), tone: .caution)
        }
        func tools(_ refs: [ToolRef]) {
            let names = refs.map { $0.name.lowercased() }
            if refs.contains(where: \.isBuiltinShell) {
                add(
                    .shell, L("Sandbox · Runs commands"),
                    detail: L("Commands run in the sandbox, which sees only this run's workspace, not your other files."),
                    tone: .caution)
            }
            let hostScripts = refs.filter { shellTools.contains($0.name.lowercased()) && !$0.isBuiltinShell }
            if !hostScripts.isEmpty {
                add(
                    .shell, L("Runs commands on your Mac"), detail: hostScripts.map(\.name).joined(separator: ", "),
                    tone: .risky)
            }
            if names.contains(where: browserTools.contains) {
                add(.browser, L("Uses the browser"), detail: names.filter(browserTools.contains).joined(separator: ", "), tone: .risky)
            }
            if names.contains(where: macTools.contains) {
                add(.mac, L("Controls this Mac"), detail: names.filter(macTools.contains).joined(separator: ", "), tone: .risky)
            }
            if names.contains(where: fileWriteTools.contains) {
                add(.files, L("Writes files"), detail: names.filter(fileWriteTools.contains).joined(separator: ", "), tone: .caution)
            }
            if names.contains(where: mediaTools.contains) {
                add(.media, L("Makes images or video"), detail: names.filter(mediaTools.contains).joined(separator: ", "), tone: .neutral)
            }
            if names.contains(where: webTools.contains) {
                add(.network, L("Reaches the web"), detail: names.filter(webTools.contains).joined(separator: ", "), tone: .caution)
            }
            let servers = refs.compactMap(\.server).filter { !$0.isEmpty }
            if !servers.isEmpty {
                add(
                    .network, servers.count == 1 ? L("Uses \(servers[0]) (MCP)") : L("Uses \(servers.count) MCP servers"),
                    detail: Array(Set(servers)).sorted().joined(separator: ", "), tone: .caution)
            }
        }
        func model(_ slot: String, agentic: Bool) {
            switch locality(slot) {
            case .cloud: add(.cloudModel, L("Cloud model"), detail: L("Slot \(slot) runs on a cloud provider; its input leaves this Mac."), tone: .caution)
            case .local: add(.localModel, L("Local model"), detail: L("Slot \(slot) runs on this Mac."), tone: .neutral)
            case .unbound: add(.localModel, L("Model not chosen"), detail: L("Slot \(slot) has no model yet."), tone: .neutral)
            }
            if agentic { add(.agentic, L("Decides its own tool calls"), tone: .caution) }
        }

        switch node.kind {
        case .http(let spec):
            hosts(spec.hosts)
            secrets(spec.secretKeys)
        case .code(let spec):
            hosts(spec.network)
            secrets(spec.secrets)
            if spec.language == .python {
                add(.shell, L("Runs Python in the sandbox"), tone: .caution)
            }
        case .tool(let spec):
            tools([spec.tool])
        case .inference(let spec):
            if case .agentic(let refs, _) = spec.mode {
                model(spec.modelSlot, agentic: true)
                tools(refs)
            } else {
                model(spec.modelSlot, agentic: false)
            }
        case .dialog:
            add(.asksUser, L("Asks you mid-run"), tone: .neutral)
        case .wait:
            add(.waits, L("Waits"), tone: .neutral)
        case .media(let spec):
            add(
                .media, spec.action == .video ? L("Makes video") : L("Makes images"),
                detail: L("Runs on \(spec.model.label). Files join the run's files."), tone: .neutral)
            if spec.model.locality == .remote {
                add(
                    .cloudModel, L("Billable provider"),
                    detail: L("Sends the prompt (and any source image) to a connected provider, which charges per job."),
                    tone: .caution)
            } else if spec.model.locality == .any {
                add(.localModel, L("Local model, else provider"), detail: L("Prefers a model on this Mac; uses a connected provider when none is installed."), tone: .neutral)
            } else {
                add(.localModel, L("Local model"), detail: L("Runs on this Mac; nothing leaves it."), tone: .neutral)
            }
        case .reply(let spec):
            add(
                .replies, L("Replies in the conversation"),
                detail: spec.hasFile
                    ? L("Posts a message and a file to the channel conversation that started the run.")
                    : L("Posts a message to the channel conversation that started the run."),
                tone: .caution)
        case .state(let spec):
            let table = spec.table ?? StateSpec.defaultTable
            switch spec.action {
            case .get, .list: add(.storesData, L("Reads stored data"), detail: L("Table “\(table)” of this workflow."), tone: .neutral)
            case .set, .increment: add(.storesData, L("Stores data"), detail: L("Writes table “\(table)”, kept between runs."), tone: .neutral)
            case .delete, .clear: add(.storesData, L("Removes stored data"), detail: L("Table “\(table)” of this workflow."), tone: .neutral)
            }
        case .workflow(let spec):
            add(.subworkflow, L("Runs “\(spec.workflow)”"), detail: L("Another installed workflow, with its own steps and access."), tone: .caution)
        case .agent(let spec):
            if spec.workspace != nil {
                add(
                    .delegates, L("Asks \(spec.agent), a teammate's agent"),
                    detail: L("A teammate's shared agent runs the task on their Mac; the task text leaves this Mac."),
                    tone: .caution)
            } else {
                add(
                    .delegates, L("Asks \(spec.agent)"),
                    detail: L("Another agent on this Mac, with its own model, tools, and permissions."), tone: .caution)
            }
        case .map(let spec):
            add(.fanOut, L("Repeats per item, \(spec.concurrency) at a time"), tone: .neutral)
            out += badges(for: spec.body(parentID: node.id), in: definition, locality: locality, history: nil)
                .filter { $0.kind != .cost }
                .map { badge in
                    guard badge.kind == .replies else { return badge }
                    var badge = badge
                    badge.detail = L(
                        "Posts once per item to the channel conversation that started the run, up to \(ReplySpec.maximumRepliesPerRun) messages per run."
                    )
                    return badge
                }
        case nil:
            break
        }
        var isMap = false
        if case .map = node.kind { isMap = true }
        if !isMap, WorkflowAccessScope.touchesMac(node, in: definition) {
            out.insert(
                WorkflowStepBadge(
                    kind: .yourMac, label: WorkflowAccessScope.Place.mac.title,
                    detail: L("Works with files or apps on your Mac, beyond this run's workspace."), tone: .neutral),
                at: 0)
        }

        if let history, history.runs > 0 {
            var parts: [String] = []
            if let ms = history.averageMs { parts.append(Self.duration(ms)) }
            if let tokens = history.averageTokens, tokens > 0 { parts.append(L("~\(Self.compact(tokens)) tokens")) }
            if !parts.isEmpty {
                let detail =
                    history.failures > 0
                    ? L("Across \(history.runs) past runs; failed \(history.failures) time(s).")
                    : L("Across \(history.runs) past runs.")
                add(.cost, parts.joined(separator: " · "), detail: detail, tone: history.failures > 0 ? .caution : .neutral)
            }
        }
        // One badge per kind+label.
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    /// Per-step averages over `runs` for every step of `definition`.
    public static func history(from runs: [WorkflowRun]) -> [String: History] {
        var samples: [String: (count: Int, ms: [Int], tokens: [Int], failures: Int)] = [:]
        for run in runs {
            for node in run.nodes where node.status != .pending && node.status != .skipped {
                var s = samples[node.nodeID] ?? (0, [], [], 0)
                s.count += 1
                if let ms = node.durationMs { s.ms.append(ms) }
                let tokens = (node.inputTokens ?? 0) + (node.outputTokens ?? 0)
                if tokens > 0 { s.tokens.append(tokens) }
                if node.status == .failed { s.failures += 1 }
                samples[node.nodeID] = s
            }
        }
        return samples.mapValues { s in
            History(
                runs: s.count,
                averageMs: s.ms.isEmpty ? nil : s.ms.reduce(0, +) / s.ms.count,
                averageTokens: s.tokens.isEmpty ? nil : s.tokens.reduce(0, +) / s.tokens.count,
                failures: s.failures)
        }
    }

    /// Where the model bound to `slot` runs, from install bindings and the
    /// model catalog.
    static func locality(
        slot: String, bindings: InstallBindings, catalog: ConfigModelReference.Catalog
    ) -> WorkflowModelLocality {
        guard let id = bindings.models[slot], !id.isEmpty else { return .unbound }
        return SetupChecker.isLocalModel(id, catalog: catalog) ? .local : .cloud
    }

    /// The badges for every step, keyed by node id, for a tool result.
    public static func report(
        _ definition: WorkflowDefinition, locality: (String) -> WorkflowModelLocality, history: [String: History] = [:]
    ) -> [[String: Any]] {
        definition.nodes.compactMap { node in
            let badges = badges(for: node, in: definition, locality: locality, history: history[node.id])
            guard !badges.isEmpty else { return nil }
            return [
                "node_id": node.id,
                "badges": badges.map { badge -> [String: Any] in
                    var row: [String: Any] = ["kind": badge.kind.rawValue, "label": badge.label, "tone": badge.tone.rawValue]
                    if let detail = badge.detail { row["detail"] = detail }
                    return row
                },
            ]
        }
    }

    static func duration(_ ms: Int) -> String {
        if ms < 1_000 { return L("~\(ms) ms") }
        if ms < 60_000 { return L("~\(String(format: "%.0f", Double(ms) / 1000)) s") }
        return L("~\(String(format: "%.1f", Double(ms) / 60_000)) min")
    }

    static func compact(_ n: Int) -> String {
        if n < 1_000 { return String(n) }
        if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1000).replacingOccurrences(of: ".0k", with: "k") }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }
}

// MARK: - Test evidence

/// The tests a save stands on: runs of the draft since its steps last
/// changed, and whether the pending change is one that needs a passing run.
public struct WorkflowTestEvidence: Equatable, Sendable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var runID: UUID
        /// The example the input matches, or "Test run".
        public var label: String
        public var status: WorkflowRunStatus
        public var startedAt: Date
        public var durationMs: Int?
        public var failedStep: String?
        public var error: String?
        /// A short rendering of the output, for the save card.
        public var outputPreview: String?
        /// Set when a step ran on a model other than the one its slot
        /// requires; the run then does not count as a pass.
        public var modelMismatch: String?

        public var id: UUID { runID }
    }

    /// Newest first; only runs started after the steps last changed.
    public var rows: [Row]
    public var passed: Int
    public var failed: Int
    /// When the steps, edges, schemas, or output last changed.
    public var changedAt: Date?
    /// The pending change touches steps, edges, schemas, or output (not
    /// only the name or summary), so a passing run is required.
    public var nonTrivial: Bool
    /// What the change does, in the diff's words, against the saved base.
    public var changeLines: [String]

    public var satisfied: Bool { !nonTrivial || passed > 0 }

    /// Why a save should wait, or nil.
    public var blocker: String? {
        guard nonTrivial, passed == 0 else { return nil }
        if let mismatch = rows.lazy.compactMap(\.modelMismatch).first {
            return L("\(mismatch) Test again on the required model before saving.")
        }
        if failed > 0 { return L("The latest test failed. Fix the step and test again before saving.") }
        return L("It hasn't passed a test since the steps changed. Run a test first.")
    }

    public static let empty = WorkflowTestEvidence(rows: [], passed: 0, failed: 0, changedAt: nil, nonTrivial: false, changeLines: [])

    /// `base` is the saved workflow the draft continues (nil for a new one).
    /// `requiredModels` maps each `always` slot to the model id it must run
    /// on; a completed run whose step ran elsewhere is not a pass.
    public static func evidence(
        for draft: WorkflowDraft, runs: [WorkflowRun], base: WorkflowDefinition?,
        requiredModels: [String: String] = [:]
    ) -> WorkflowTestEvidence {
        let current = draft.definition
        let baseDefinition = base ?? WorkflowDefinition()
        let changeLines = WorkflowDiff.plainLines(from: baseDefinition, to: current)
        let nonTrivial = !changeLines.isEmpty && !current.nodes.isEmpty

        let changedAt = stepsChangedAt(draft)
        let since = changedAt ?? (base == nil && !current.nodes.isEmpty ? draft.createdAt : nil)

        let relevant = runs
            .filter { ($0.isTest || $0.ephemeral) && $0.status.isTerminal }
            .filter { run in since.map { run.startedAt >= $0 } ?? true }
            .sorted { $0.startedAt > $1.startedAt }
        let rows = relevant.map { run -> Row in
            let example = current.examples.first { $0.input == run.input }?.name
            return Row(
                runID: run.id,
                label: example.map { L("Example “\($0)”") } ?? (run.ephemeral ? L("Run from chat") : L("Test run")),
                status: run.status,
                startedAt: run.startedAt,
                durationMs: run.finishedAt.map { Int($0.timeIntervalSince(run.startedAt) * 1000) },
                failedStep: run.error?.nodeID, error: run.error?.reason,
                outputPreview: run.output.map { preview($0) },
                modelMismatch: modelMismatch(in: run, definition: current, requiredModels: requiredModels))
        }
        return WorkflowTestEvidence(
            rows: rows, passed: rows.filter { $0.status == .completed && $0.modelMismatch == nil }.count,
            failed: rows.filter { $0.status == .failed }.count, changedAt: changedAt, nonTrivial: nonTrivial,
            changeLines: changeLines)
    }

    /// The first inference step of `run` that ran on a model other than the
    /// one its slot requires, in words, or nil.
    static func modelMismatch(
        in run: WorkflowRun, definition: WorkflowDefinition, requiredModels: [String: String]
    ) -> String? {
        guard !requiredModels.isEmpty else { return nil }
        for node in definition.nodes {
            guard case .inference(let spec) = node.kind, let required = requiredModels[spec.modelSlot],
                let ran = run.nodes.first(where: { $0.nodeID == node.id })?.model,
                ran.caseInsensitiveCompare(required) != .orderedSame
            else { continue }
            return L("“\(node.name)” ran on \(ran), but slot “\(spec.modelSlot)” requires \(required).")
        }
        return nil
    }

    /// When the steps last changed: the newest history entry whose "before"
    /// differs from the current definition. Later entries changed only the
    /// name or summary, which never invalidates a test. Nil when the steps
    /// never changed since the draft began.
    public static func stepsChangedAt(_ draft: WorkflowDraft) -> Date? {
        let current = draft.definition
        for edit in draft.history.reversed() where edit.definition != current {
            return edit.at
        }
        return nil
    }

    static func preview(_ value: JSONValue, limit: Int = 160) -> String {
        let text: String
        switch value {
        case .string(let s): text = s
        case .object(let o):
            text = o.keys.sorted().prefix(6).map { key in
                let v = o[key] ?? .null
                let rendered: String
                switch v {
                case .string(let s): rendered = "\"\(s)\""
                case .array(let a): rendered = "[\(a.count) items]"
                case .object: rendered = "{…}"
                default: rendered = v.compactJSONString
                }
                return "\(key): \(rendered)"
            }.joined(separator: ", ")
        default: text = value.compactJSONString
        }
        let flat = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    /// Foundation form for tool results and the save prompt.
    public var summary: [String: Any] {
        var out: [String: Any] = [
            "passed": passed, "failed": failed, "non_trivial": nonTrivial, "satisfied": satisfied,
            "runs": rows.map { row -> [String: Any] in
                var r: [String: Any] = ["run_id": row.runID.uuidString, "label": row.label, "status": row.status.rawValue]
                if let step = row.failedStep { r["failed_step"] = step }
                if let error = row.error { r["error"] = error }
                if let ms = row.durationMs { r["duration_ms"] = ms }
                if let mismatch = row.modelMismatch { r["model_mismatch"] = mismatch }
                return r
            },
        ]
        if let blocker { out["blocker"] = blocker }
        if !changeLines.isEmpty { out["changes"] = changeLines }
        return out
    }
}
