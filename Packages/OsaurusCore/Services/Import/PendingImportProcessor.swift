//
//  PendingImportProcessor.swift
//  osaurus
//
//  Applies the requests `osaurus import` queues under
//  `~/.osaurus/import/pending/`: at launch for anything queued while the
//  app was closed, and on demand from the loopback `/admin/import/*`
//  endpoints while it runs. Requests apply one at a time, oldest first.
//
//  Within a request, skills install first, then MCP servers, then harness
//  runtimes, then agents, so an agent's skill allow-list, server tools and
//  runtime exist when it is created; settings go last. Removals run the
//  other way round. Every item goes through the same paths as the rest of
//  the app (SkillManager, ConfigPlanner / ConfigApplier, the Settings
//  stores), and `installed.json` receipts record what each bundle owns so
//  updates and removals never touch anything else.
//
//  Settings are shared, so they follow their own rules: `update` leaves a
//  setting the user changed since the bundle set it, two bundles may not
//  ask for opposite values, and removing a bundle leaves its settings as
//  they are.
//

import Foundation
import OsaurusRepository
import os

private let log = Logger(subsystem: "ai.osaurus", category: "Import")

@MainActor
public final class PendingImportProcessor {
    public static let shared = PendingImportProcessor()

    /// How long agents wait for the MCP servers they use to connect, so
    /// their tools resolve by group name.
    var connectTimeout: TimeInterval = 30

    var settings: ImportSettingsAccess = LiveImportSettings.shared

    private var tail: Task<Void, Never>?

    init() {}

    // MARK: - Entry points

    /// Launch hook: applies what was queued while the app was closed and
    /// tells the user which agents arrived.
    public func processAtLaunch(waitForPlugins: Bool) async {
        guard !ImportQueue.pending().isEmpty else { return }
        if waitForPlugins { await PluginManager.shared.ensurePromptCatalogReady() }
        let results = await processAll()
        await applyDeferredSettings()
        announce(results)
    }

    /// Restarts the server for settings an import changed, such as Allowed
    /// Origins. `/admin/import/apply` calls this after it has answered.
    public func applyDeferredSettings() async {
        await settings.applyDeferredChanges()
    }

    /// Applies every pending request, oldest first.
    @discardableResult
    public func processAll() async -> [ImportResult] {
        await serialized {
            var results: [ImportResult] = []
            for pending in ImportQueue.pending() {
                results.append(await self.apply(pending))
            }
            return results
        }
    }

    /// Applies pending requests up to and including `requestId` (older ones
    /// first, so order holds) and returns that request's result. A request
    /// another pass already applied returns its saved result.
    public func process(requestId: String) async -> ImportResult? {
        await serialized {
            for pending in ImportQueue.pending() {
                let result = await self.apply(pending)
                if pending.request.id == requestId { return result }
            }
            return ImportQueue.result(id: requestId)
        }
    }

    /// The `osaurus import validate` check against this Mac: the strict
    /// schema and plan validation for agents and servers, plus ownership
    /// conflicts. Changes nothing.
    public func plan(bundleAt url: URL, operations: [ImportOperation]) async -> (issues: [String], warnings: [String]) {
        let bundle: OsaurusBundle
        do {
            bundle = try OsaurusBundle.load(from: url)
        } catch let error as OsaurusBundleError {
            return (error.issues, [])
        } catch {
            return ([error.localizedDescription], [])
        }
        await SkillManager.shared.refresh()
        let receipts = ImportQueue.loadReceipts()
        var issues: [String] = []
        var warnings: [String] = []
        for op in operations.sorted(by: { $0.kind < $1.kind }) {
            let label = "\(op.kind.rawValue) \"\(op.name)\""
            do {
                let item = try prepare(op, bundle: bundle, bundleVersion: bundle.manifest.version, receipts: receipts)
                switch item.decision {
                case .conflict(let message): issues.append("\(label): \(message)")
                case .skip(let message): warnings.append("\(label): \(message)")
                case .create, .replace, .unchanged: break
                }
                warnings += item.notes.map { "\(label): \($0)" }
            } catch let failure as PrepareFailure {
                issues.append("\(label): \(failure.message)")
            } catch {
                issues.append("\(label): \(error.localizedDescription)")
            }
        }
        return (issues, warnings)
    }

    private func serialized<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await body()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    // MARK: - One request

    func apply(_ pending: PendingImport) async -> ImportResult {
        let request = pending.request
        var receipts = ImportQueue.loadReceipts()
        var items: [ImportItemResult] = []
        await SkillManager.shared.refresh()

        let installs = request.operations.filter { $0.action != .remove }.sorted { $0.kind < $1.kind }
        let removals = request.operations.filter { $0.action == .remove }
            .sorted { Self.removalOrder($0.kind) < Self.removalOrder($1.kind) }

        if !installs.isEmpty {
            do {
                let bundle = try OsaurusBundle.load(from: pending.bundleDirectory)
                guard bundle.id == request.bundleId else {
                    throw OsaurusBundleError(issues: [
                        "The queued copy is bundle \(bundle.id), not \(request.bundleId)."
                    ])
                }
                var waitedForServers = false
                for op in installs {
                    if op.kind == .agent && !waitedForServers {
                        waitedForServers = true
                        let servers = installs.filter { $0.kind == .agent }
                            .flatMap { bundle.agent(named: $0.name)?.mcpServers ?? [] }
                        await waitForServers(named: servers)
                    }
                    items.append(await install(op, bundle: bundle, request: request, receipts: &receipts))
                    saveReceipts(receipts)
                }
            } catch {
                let message = "The queued bundle copy could not be read: \(Self.describe(error))"
                items += installs.map {
                    ImportItemResult(kind: $0.kind, name: $0.name, action: $0.action, status: .failed, message: message)
                }
            }
        }

        var removed = Set<String>()
        for op in removals {
            items += await remove(op, request: request, receipts: &receipts, removed: &removed)
            saveReceipts(receipts)
        }

        let result = ImportResult(requestId: request.id, bundleId: request.bundleId, items: items)
        do {
            try ImportQueue.complete(pending, result: result)
        } catch {
            log.error("Could not record import result \(request.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        log.notice(
            "Applied import \(request.id, privacy: .public) from \(request.bundleId, privacy: .public): \(result.status.rawValue, privacy: .public)"
        )
        return result
    }

    private func saveReceipts(_ receipts: [ImportReceipt]) {
        do {
            try ImportQueue.saveReceipts(receipts)
        } catch {
            log.error("Could not save import receipts: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func removalOrder(_ kind: BundleItemKind) -> Int {
        switch kind {
        case .agent: return 0
        case .skill: return 1
        case .mcp: return 2
        case .harnessRuntime: return 3
        case .setting: return 4
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? OsaurusBundleError { return error.issues.joined(separator: " ") }
        if let error = error as? ConfigPlanIssues { return error.issues.joined(separator: " ") }
        return error.localizedDescription
    }

    // MARK: - Preparing an item

    private struct PrepareFailure: Error {
        var message: String
    }

    private enum Decision: Equatable {
        case create
        case replace
        case unchanged
        case skip(String)
        case conflict(String)
    }

    private enum Payload {
        case skill(source: OsaurusBundle.Skill, existing: Skill?)
        case mcp(entry: MCPServerEntry, existingId: UUID?)
        case harnessRuntime(entry: HarnessRuntimeEntry)
        case agent(
            entry: AgentEntry, existingId: UUID?, quickActions: [AgentQuickAction]?,
            source: OsaurusBundle.Agent)
        case setting(BundleSetting, value: BundleSettingValue)
    }

    private struct PreparedItem {
        var op: ImportOperation
        var hash: String
        var receipt: ImportReceipt?
        var decision: Decision
        var payload: Payload
        /// Things the user should know that do not stop the item.
        var notes: [String] = []
        /// The item applies but leaves something for the user to finish.
        var needsUser = false
    }

    /// Resolves an operation against the bundle, this Mac, and the
    /// receipts: what it would install, and whether it may.
    private func prepare(
        _ op: ImportOperation, bundle: OsaurusBundle, bundleVersion: String?, receipts: [ImportReceipt]
    ) throws -> PreparedItem {
        guard let hash = bundle.contentHash(kind: op.kind, name: op.name) else {
            throw PrepareFailure(message: "Not found in the bundle.")
        }
        let receipt =
            receipts.first { $0.bundleId == bundle.id && $0.matches(kind: op.kind, name: op.name) }
            ?? receipts.first { $0.matches(kind: op.kind, name: op.name) }

        switch op.kind {
        case .skill:
            guard let source = bundle.skill(named: op.name) else {
                throw PrepareFailure(message: "Not found in the bundle.")
            }
            let owned = receipt?.bundleId == bundle.id ? receipt : nil
            let existing =
                owned?.skillDirectory.flatMap { dir in
                    SkillManager.shared.skills.first { $0.directoryName?.lowercased() == dir.lowercased() }
                } ?? SkillManager.shared.skill(named: source.name)
            if let existing, existing.isBuiltIn || existing.isFromPlugin {
                return PreparedItem(
                    op: op, hash: hash, receipt: receipt,
                    decision: .conflict(
                        "A \(existing.isBuiltIn ? "built-in" : "plugin") skill is already named \"\(existing.name)\". "
                            + "Rename the bundle's skill."),
                    payload: .skill(source: source, existing: existing))
            }
            let decision = decide(
                op, bundle: bundle, bundleVersion: bundleVersion, hash: hash, receipt: receipt,
                exists: existing != nil, what: "skill")
            return PreparedItem(
                op: op, hash: hash, receipt: receipt, decision: decision,
                payload: .skill(source: source, existing: existing))

        case .mcp:
            guard let raw = try? bundle.rawMCPServerEntries()[op.name.lowercased()] else {
                throw PrepareFailure(message: "Not found in the bundle.")
            }
            var entry: MCPServerEntry
            do {
                let data = try JSONSerialization.data(withJSONObject: raw)
                entry = try JSONDecoder().decode(MCPServerEntry.self, from: data)
            } catch {
                throw PrepareFailure(message: "The server entry does not decode: \(error.localizedDescription)")
            }
            let providers = ConfigExporter.manageableMCPProviders()
            let owned = receipt?.bundleId == bundle.id ? receipt : nil
            let existing =
                owned?.mcpProviderId.flatMap(UUID.init(uuidString:)).flatMap { id in
                    providers.first { $0.id == id }
                } ?? providers.first { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }
            let decision = decide(
                op, bundle: bundle, bundleVersion: bundleVersion, hash: hash, receipt: receipt,
                exists: existing != nil, what: "MCP server")
            // A server the user renamed keeps its name; the applier matches by it.
            if let existing, decision == .replace { entry.name = existing.name }
            var document = OsaurusConfigDocument()
            document.version = 1
            document.mcpServers = [entry]
            do {
                _ = try ConfigPlanner.plan(document: document, prune: false)
            } catch {
                throw PrepareFailure(message: Self.describe(error))
            }
            return PreparedItem(
                op: op, hash: hash, receipt: receipt, decision: decision,
                payload: .mcp(entry: entry, existingId: existing?.id))

        case .harnessRuntime:
            guard let raw = try? bundle.rawHarnessRuntimeEntries()[Self.runtimeKey(op.name)] else {
                throw PrepareFailure(message: "Not found in the bundle.")
            }
            var entry: HarnessRuntimeEntry
            do {
                let data = try JSONSerialization.data(withJSONObject: raw)
                entry = try JSONDecoder().decode(HarnessRuntimeEntry.self, from: data)
            } catch {
                throw PrepareFailure(message: "The runtime entry does not decode: \(error.localizedDescription)")
            }
            let owned = receipt?.bundleId == bundle.id ? receipt : nil
            let existing =
                owned?.harnessRuntimeId.flatMap(UUID.init(uuidString:)).flatMap {
                    HarnessRuntimeStore.shared.runtime(id: $0)
                } ?? ConfigHarness.runtime(named: entry.name)
            let decision = decide(
                op, bundle: bundle, bundleVersion: bundleVersion, hash: hash, receipt: receipt,
                exists: existing != nil, what: "harness runtime")
            // A runtime the user renamed keeps its name; the applier matches by it.
            if let existing, decision == .replace { entry.name = existing.displayName }
            var document = OsaurusConfigDocument()
            document.version = 1
            document.harnessRuntimes = [entry]
            do {
                _ = try ConfigPlanner.plan(document: document, prune: false)
            } catch {
                throw PrepareFailure(message: Self.describe(error))
            }
            return PreparedItem(
                op: op, hash: hash, receipt: receipt, decision: decision,
                payload: .harnessRuntime(entry: entry))

        case .agent:
            guard let source = bundle.agent(named: op.name) else {
                throw PrepareFailure(message: "Not found in the bundle.")
            }
            let template: Template
            do {
                template = try Template.parse(String(contentsOf: source.file, encoding: .utf8))
            } catch {
                throw PrepareFailure(message: "The agent file does not parse: \(error.localizedDescription)")
            }
            var entry = template.resolvedEntry()
            var notes: [String] = []
            var needsUser = false
            var planEntry = entry
            switch template.modelResolution() {
            case .available:
                break
            case .fallbackToDefault(let requested):
                notes.append("Model \(requested) is not on this Mac; the agent uses the default model.")
            case .blocked(let requested):
                // Keep the pin: setup asks for the model instead of silently
                // running the agent on another one.
                entry.model = .value(requested)
                needsUser = true
                notes.append(
                    "Needs model \(requested), which is not installed. Download it, or choose another "
                        + "model for the agent.")
            }

            let owned = receipt?.bundleId == bundle.id ? receipt : nil
            let agents = AgentManager.shared.agents
            let existing =
                owned?.agentId.flatMap(UUID.init(uuidString:)).flatMap { id in agents.first { $0.id == id } }
                ?? agents.first { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }
            if let existing, existing.isBuiltIn {
                return PreparedItem(
                    op: op, hash: hash, receipt: receipt,
                    decision: .conflict("\"\(existing.name)\" is a built-in agent. Rename the bundle's agent."),
                    payload: .agent(entry: entry, existingId: existing.id, quickActions: nil, source: source))
            }
            let decision = decide(
                op, bundle: bundle, bundleVersion: bundleVersion, hash: hash, receipt: receipt,
                exists: existing != nil, what: "agent")
            // An agent the user renamed keeps its name; the applier matches by it.
            if let existing, decision == .replace { entry.name = existing.name }
            planEntry.name = entry.name
            var document = OsaurusConfigDocument()
            document.version = 1
            document.agents = [planEntry]
            // The runtime installs ahead of the agent in the same request.
            if let runtime = source.harnessRuntime.flatMap(bundle.harnessRuntime(named:)) {
                document.harnessRuntimes = [Self.runtimeEntry(runtime)]
            }
            do {
                _ = try ConfigPlanner.plan(document: document, prune: false)
            } catch {
                throw PrepareFailure(message: Self.describe(error))
            }
            var item = PreparedItem(
                op: op, hash: hash, receipt: receipt, decision: decision,
                payload: .agent(
                    entry: entry, existingId: existing?.id, quickActions: template.quickActions, source: source))
            item.notes = notes
            item.needsUser = needsUser
            return item

        case .setting:
            guard let entry = bundle.setting(named: op.name) else {
                throw PrepareFailure(message: "Not found in the bundle.")
            }
            let decision = decideSetting(
                op, setting: entry.setting, wanted: entry.value, bundle: bundle, bundleVersion: bundleVersion,
                receipts: receipts)
            return PreparedItem(
                op: op, hash: hash, receipt: receipt, decision: decision,
                payload: .setting(entry.setting, value: entry.value))
        }
    }

    /// Ownership rules for a shared setting. `install` always sets it;
    /// `update` leaves it once the user has changed what the bundle set.
    /// A bundle may not ask for the opposite of what another bundle set.
    private func decideSetting(
        _ op: ImportOperation, setting: BundleSetting, wanted: BundleSettingValue, bundle: OsaurusBundle,
        bundleVersion: String?, receipts: [ImportReceipt]
    ) -> Decision {
        let current = settings.value(of: setting)
        let own = receipts.first { $0.bundleId == bundle.id && $0.matches(kind: .setting, name: setting.key) }
        if setting.kind == .toggle,
            let other = receipts.first(where: {
                $0.bundleId != bundle.id && $0.matches(kind: .setting, name: setting.key)
                    && $0.settingValue != nil && $0.settingValue != wanted
            }), let theirs = other.settingValue
        {
            return .conflict(
                "\(other.bundleId) turned it \(theirs). Change it in \(setting.location), or remove that "
                    + "bundle's setting first.")
        }
        guard let own else { return setting.isSatisfied(wanted, by: current) ? .unchanged : .create }
        if let installed = own.bundleVersion.flatMap(SemanticVersion.parse),
            let incoming = bundleVersion.flatMap(SemanticVersion.parse),
            installed > incoming
        {
            return .skip("Version \(installed) is installed, newer than \(incoming). Nothing changed.")
        }
        if op.action == .update, let applied = own.settingValue, !setting.isSatisfied(applied, by: current) {
            return .skip(
                "Changed in \(setting.location) since \(bundle.id) set it; left as it is. "
                    + "Run install to set it again.")
        }
        return setting.isSatisfied(wanted, by: current) ? .unchanged : .replace
    }

    private static func runtimeKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func runtimeEntry(_ ref: OsaurusBundleManifest.HarnessRuntimeReference) -> HarnessRuntimeEntry {
        var entry = HarnessRuntimeEntry(name: ref.name)
        entry.kind = ref.kind
        entry.executable = ref.executable
        entry.arguments = ref.arguments
        entry.environment = ref.environment
        return entry
    }

    /// Ownership rules. An item another bundle (or the user) owns is never
    /// touched. `update` does not bring back an item the user deleted.
    private func decide(
        _ op: ImportOperation, bundle: OsaurusBundle, bundleVersion: String?, hash: String,
        receipt: ImportReceipt?, exists: Bool, what: String
    ) -> Decision {
        guard let receipt else {
            if exists {
                return .conflict(
                    "A \(what) named \"\(op.name)\" already exists and was not installed by \(bundle.id). "
                        + "Rename or remove it in Osaurus, then run the import again.")
            }
            return .create
        }
        guard receipt.bundleId == bundle.id else {
            return .conflict("Installed by another bundle, \(receipt.bundleId).")
        }
        if let installed = receipt.bundleVersion.flatMap(SemanticVersion.parse),
            let incoming = bundleVersion.flatMap(SemanticVersion.parse),
            installed > incoming
        {
            return .skip("Version \(installed) is installed, newer than \(incoming). Nothing changed.")
        }
        guard exists else {
            if op.action == .update {
                return .skip("Removed in Osaurus since it was installed. Run install to add it back.")
            }
            return .create
        }
        let unfinished = receipt.needsUserAction == true || !(receipt.pendingSecrets ?? []).isEmpty
        if receipt.contentHash == hash && !unfinished { return .unchanged }
        return .replace
    }

    // MARK: - Install / update

    private func install(
        _ op: ImportOperation, bundle: OsaurusBundle, request: ImportRequest, receipts: inout [ImportReceipt]
    ) async -> ImportItemResult {
        func result(_ status: ImportItemStatus, _ message: String?, pending: [String]? = nil, name: String? = nil)
            -> ImportItemResult
        {
            ImportItemResult(
                kind: op.kind, name: name ?? op.name, action: op.action, status: status, message: message,
                pendingSecrets: pending)
        }

        let item: PreparedItem
        do {
            item = try prepare(op, bundle: bundle, bundleVersion: request.bundleVersion, receipts: receipts)
        } catch let failure as PrepareFailure {
            return result(.failed, failure.message)
        } catch {
            return result(.failed, error.localizedDescription)
        }

        switch item.decision {
        case .conflict(let message): return result(.failed, message)
        case .skip(let message): return result(.skipped, message)
        case .unchanged:
            let own = receipts.first(where: { $0.bundleId == bundle.id && $0.matches(kind: op.kind, name: op.name) })
            if case .setting(let setting, let value) = item.payload, own?.settingValue != value {
                // Already the way the bundle wants it: record it, so a later
                // update can tell when the user changes it.
                var receipt =
                    own
                    ?? ImportReceipt(
                        bundleId: bundle.id, bundleName: bundle.manifest.name, bundleVersion: nil,
                        kind: .setting, name: setting.key, explicit: op.explicit, contentHash: item.hash)
                receipt.bundleVersion = request.bundleVersion
                receipt.contentHash = item.hash
                receipt.settingValue = value
                receipt.updatedAt = Date()
                upsert(receipt, into: &receipts)
                return result(.unchanged, "\(setting.title) is already \(settings.value(of: setting)).")
            }
            // Keep every item of a bundle on one version, so a later older
            // version is skipped for this item like for its siblings.
            if var receipt = own, receipt.bundleVersion != request.bundleVersion {
                receipt.bundleVersion = request.bundleVersion
                receipt.bundleName = request.bundleName ?? receipt.bundleName
                upsert(receipt, into: &receipts)
            }
            return result(.unchanged, nil)
        case .create, .replace: break
        }

        let risks = bundle.risks(for: [BundleItemRef(kind: op.kind, name: op.name, explicit: op.explicit)])
        if !risks.isEmpty && !request.confirmHighRisk {
            return result(
                .failed, "High-risk change not confirmed: \(risks.joined(separator: "; ")). Re-run with --yes.")
        }

        var receipt =
            item.receipt.flatMap { $0.bundleId == bundle.id ? $0 : nil }
            ?? ImportReceipt(
                bundleId: bundle.id, bundleName: nil, bundleVersion: nil, kind: op.kind, name: op.name,
                explicit: op.explicit, contentHash: item.hash)
        receipt.bundleName = bundle.manifest.name
        receipt.bundleVersion = bundle.manifest.version
        receipt.contentHash = item.hash
        receipt.explicit = receipt.explicit || op.explicit
        receipt.updatedAt = Date()
        let verb = item.decision == .replace ? "Updated" : "Installed"

        switch item.payload {
        case .skill(let source, let existing):
            do {
                let installed = try await SkillManager.shared.installSkill(
                    fromDirectory: source.directory, replacing: item.decision == .replace ? existing : nil)
                receipt.skillDirectory = installed.directoryName ?? OsaurusBundle.skillSlug(for: installed.name)
                receipt.needsUserAction = nil
                upsert(receipt, into: &receipts)
                return result(.done, "\(verb) skill \(installed.name).")
            } catch {
                return result(.failed, error.localizedDescription)
            }

        case .mcp(let entry, _):
            var document = OsaurusConfigDocument()
            document.version = 1
            document.mcpServers = [entry]
            let rows = await ConfigApplier.apply(document: document, prune: false, options: .bundleImport)
            guard let row = rows.first(where: { $0.section == "mcp_servers" }) else {
                return result(.failed, "The server was not applied.")
            }
            if row.status == .failed { return result(.failed, row.message, pending: nonEmpty(row.unresolvedSecretRefs)) }
            let provider = MCPProviderManager.shared.configuration.providers.first {
                $0.name.caseInsensitiveCompare(entry.name) == .orderedSame
            }
            receipt.mcpProviderId = provider?.id.uuidString
            receipt.pendingSecrets = nonEmpty(row.unresolvedSecretRefs)
            receipt.needsUserAction = row.status == .needsUserAction ? true : nil
            upsert(receipt, into: &receipts)
            let status: ImportItemStatus = row.status == .needsUserAction ? .needsUserAction : .done
            return result(status, row.message ?? "\(verb) MCP server.", pending: receipt.pendingSecrets, name: entry.name)

        case .harnessRuntime(let entry):
            var document = OsaurusConfigDocument()
            document.version = 1
            document.harnessRuntimes = [entry]
            let rows = await ConfigApplier.apply(document: document, prune: false, options: .bundleImport)
            guard let row = rows.first(where: { $0.section == "harness_runtimes" }) else {
                return result(.failed, "The runtime was not applied.")
            }
            if row.status == .failed { return result(.failed, row.message) }
            guard let runtime = ConfigHarness.runtime(named: entry.name) else {
                return result(.failed, "The runtime was applied but could not be found afterwards.")
            }
            receipt.harnessRuntimeId = runtime.id.uuidString
            receipt.needsUserAction = nil
            upsert(receipt, into: &receipts)
            return result(.done, "\(verb) harness runtime \(runtime.displayName).", name: runtime.displayName)

        case .agent(let entry, _, let quickActions, let source):
            let bundleRuntime = source.harnessRuntime.flatMap(bundle.harnessRuntime(named:))
            if let bundleRuntime,
                !receipts.contains(where: {
                    $0.bundleId == bundle.id && $0.matches(kind: .harnessRuntime, name: bundleRuntime.name)
                })
            {
                return result(
                    .failed, "Its harness runtime \"\(bundleRuntime.name)\" from this bundle is not installed.")
            }
            var document = OsaurusConfigDocument()
            document.version = 1
            document.agents = [entry]
            let rows = await ConfigApplier.apply(document: document, prune: false, options: .bundleImport)
            guard let row = rows.first(where: { $0.section == "agents" }) else {
                return result(.failed, "The agent was not applied.")
            }
            if row.status == .failed { return result(.failed, row.message) }
            guard
                var agent = AgentManager.shared.agents.first(where: {
                    !$0.isBuiltIn && $0.name.caseInsensitiveCompare(entry.name) == .orderedSame
                })
            else {
                return result(.failed, "The agent was applied but could not be found afterwards.")
            }
            if let quickActions {
                agent.chatQuickActions = quickActions
                AgentManager.shared.update(agent)
            }
            var notes = item.notes
            if let message = row.message, !message.isEmpty { notes.insert(message, at: 0) }
            let blockers = SetupChecker.check(agent).blocking
            notes += blockers.map { "\($0.title): \($0.detail)" }
            let pendingSecrets = nonEmpty(
                Array(
                    Set(
                        source.mcpServers.flatMap { server in
                            receipts.first { $0.bundleId == bundle.id && $0.matches(kind: .mcp, name: server) }?
                                .pendingSecrets ?? []
                        })
                ).sorted())
            if pendingSecrets != nil {
                notes.append(
                    "Its MCP servers are missing secrets; once they are in the Keychain, run "
                        + "`osaurus import update` to wire their tools.")
            }
            let needsUser =
                item.needsUser || row.status == .needsUserAction || !blockers.isEmpty || pendingSecrets != nil
            receipt.agentId = agent.id.uuidString
            receipt.skills = source.skills
            receipt.mcpServers = source.mcpServers.isEmpty ? nil : source.mcpServers
            receipt.harnessRuntime = bundleRuntime?.name
            receipt.needsUserAction = needsUser ? true : nil
            upsert(receipt, into: &receipts)
            return result(
                needsUser ? .needsUserAction : .done,
                notes.isEmpty ? "\(verb) agent." : notes.joined(separator: " "),
                pending: pendingSecrets,
                name: agent.name)

        case .setting(let setting, let value):
            let stored = setting.applying(value, to: settings.value(of: setting))
            settings.set(stored, for: setting)
            var notes = ["Set \(setting.title) to \(stored)."]
            var needsUser = false
            switch (setting.id, value) {
            case (.requireLocalAccessKey, .bool(true)):
                notes.append(
                    "Apps and scripts on this Mac now need an access key for /sessions, /agents, /mcp/*, "
                        + "/admin/config/* and /admin/import/*.")
                if !settings.hasAccessKeys() {
                    needsUser = true
                    notes.append("No access key exists yet. Create one in Server → Overview.")
                }
            case (.allowedOrigins, _):
                notes.append("The server restarts to use the new list.")
            default:
                break
            }
            receipt.settingValue = value
            receipt.needsUserAction = needsUser ? true : nil
            upsert(receipt, into: &receipts)
            return result(needsUser ? .needsUserAction : .done, notes.joined(separator: " "))
        }
    }

    private func nonEmpty(_ refs: [String]) -> [String]? {
        refs.isEmpty ? nil : refs
    }

    private func upsert(_ receipt: ImportReceipt, into receipts: inout [ImportReceipt]) {
        receipts.removeAll { $0.bundleId == receipt.bundleId && $0.matches(kind: receipt.kind, name: receipt.name) }
        receipts.append(receipt)
    }

    /// Waits (bounded) for the enabled servers an agent turns on to connect,
    /// so `mcp_servers.enabled` resolves to their tools. A server that fails
    /// is reported by the agent's apply notes, not here.
    private func waitForServers(named names: [String]) async {
        let manager = MCPProviderManager.shared
        let ids = Set(
            names.compactMap { name in
                manager.configuration.providers.first {
                    $0.enabled && $0.name.caseInsensitiveCompare(name) == .orderedSame
                }?.id
            })
        guard !ids.isEmpty else { return }
        let start = Date()
        var kicked = Set<UUID>()
        while Date().timeIntervalSince(start) < connectTimeout {
            var waiting = false
            for id in ids {
                let state = manager.providerStates[id]
                if state?.isConnected == true { continue }
                if state?.isConnecting == true {
                    waiting = true
                    continue
                }
                if kicked.contains(id) && state?.lastError != nil { continue }
                // A just-added server connects on its own once its secrets
                // are stored; only nudge one that has not started.
                if Date().timeIntervalSince(start) > 2, kicked.insert(id).inserted {
                    Task { try? await manager.connect(providerId: id) }
                }
                waiting = true
            }
            guard waiting else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        log.notice("Import: MCP servers still connecting after \(Int(self.connectTimeout))s; applying agents anyway")
    }

    // MARK: - Remove

    private func remove(
        _ op: ImportOperation, request: ImportRequest, receipts: inout [ImportReceipt], removed: inout Set<String>
    ) async -> [ImportItemResult] {
        let key = Self.removalKey(op.kind, op.name)
        guard let receipt = receipts.first(where: { $0.bundleId == request.bundleId && $0.matches(kind: op.kind, name: op.name) })
        else {
            if removed.contains(key) { return [] }
            return [
                ImportItemResult(
                    kind: op.kind, name: op.name, action: .remove, status: .skipped,
                    message: "\(request.bundleId) did not install it.")
            ]
        }

        if op.kind != .agent {
            let users = referencingAgents(kind: op.kind, name: receipt.name, receipts: receipts)
            if !users.isEmpty {
                return [
                    ImportItemResult(
                        kind: op.kind, name: op.name, action: .remove, status: .failed,
                        message: "Still used by \(users.joined(separator: ", ")). Remove or change "
                            + (users.count == 1 ? "that agent" : "those agents") + " first.")
                ]
            }
        }

        var results = [await removeItem(receipt, receipts: &receipts, removed: &removed)]
        guard op.kind == .agent, results.first?.status == .done else { return results }

        // Dependencies this bundle pulled in for the agent go too, once
        // nothing uses them. Items named on their own stay.
        let dependencies =
            (receipt.skills ?? []).map { (BundleItemKind.skill, $0) }
            + (receipt.mcpServers ?? []).map { (BundleItemKind.mcp, $0) }
            + (receipt.harnessRuntime.map { [(BundleItemKind.harnessRuntime, $0)] } ?? [])
        for (kind, name) in dependencies {
            guard
                let dependency = receipts.first(where: {
                    $0.bundleId == request.bundleId && $0.matches(kind: kind, name: name)
                }),
                !dependency.explicit,
                referencingAgents(kind: kind, name: dependency.name, receipts: receipts).isEmpty
            else { continue }
            var row = await removeItem(dependency, receipts: &receipts, removed: &removed)
            if row.status == .done {
                row.message = "Removed with \(receipt.name); nothing else uses it."
            }
            results.append(row)
        }
        return results
    }

    private static func removalKey(_ kind: BundleItemKind, _ name: String) -> String {
        kind == .skill ? "skill:\(OsaurusBundle.skillSlug(for: name))" : "\(kind.rawValue):\(name.lowercased())"
    }

    /// Agents that still use a skill, server or runtime: imported agents by
    /// receipt, any agent whose skill allow-list names the skill, and any
    /// agent running on the runtime.
    private func referencingAgents(kind: BundleItemKind, name: String, receipts: [ImportReceipt]) -> [String] {
        var users: [String] = []
        for receipt in receipts where receipt.kind == .agent {
            let uses: Bool
            switch kind {
            case .skill:
                uses = (receipt.skills ?? []).contains {
                    OsaurusBundle.skillSlug(for: $0) == OsaurusBundle.skillSlug(for: name)
                }
            case .mcp:
                uses = (receipt.mcpServers ?? []).contains { $0.caseInsensitiveCompare(name) == .orderedSame }
            case .harnessRuntime:
                uses = receipt.harnessRuntime.map { Self.runtimeKey($0) == Self.runtimeKey(name) } ?? false
            case .agent, .setting:
                uses = false
            }
            if uses { users.append(receipt.name) }
        }
        if kind == .harnessRuntime,
            let id = receipts.first(where: { $0.matches(kind: .harnessRuntime, name: name) })?
                .harnessRuntimeId.flatMap(UUID.init(uuidString:))
        {
            for agent in AgentManager.shared.agents
            where AgentManager.shared.effectiveRuntime(for: agent.id) == .harness(id) && !users.contains(agent.name) {
                users.append(agent.name)
            }
        }
        if kind == .skill {
            let probe = Skill(name: name, directoryName: OsaurusBundle.skillSlug(for: name))
            for agent in AgentManager.shared.agents where !agent.isBuiltIn && agent.skillNames != nil {
                if agent.allowsSkill(probe) && !users.contains(agent.name) { users.append(agent.name) }
            }
        }
        return users
    }

    private func removeItem(
        _ receipt: ImportReceipt, receipts: inout [ImportReceipt], removed: inout Set<String>
    ) async -> ImportItemResult {
        func row(_ status: ImportItemStatus, _ message: String?) -> ImportItemResult {
            ImportItemResult(kind: receipt.kind, name: receipt.name, action: .remove, status: status, message: message)
        }
        var gone = false
        switch receipt.kind {
        case .agent:
            if let id = receipt.agentId.flatMap(UUID.init(uuidString:)), AgentManager.shared.agent(for: id) != nil {
                guard await AgentManager.shared.delete(id: id).deleted else {
                    return row(.failed, "Osaurus could not delete the agent.")
                }
            } else {
                gone = true
            }
        case .skill:
            let skill =
                receipt.skillDirectory.flatMap { dir in
                    SkillManager.shared.skills.first { $0.directoryName?.lowercased() == dir.lowercased() }
                } ?? SkillManager.shared.skill(named: receipt.name)
            if let skill, !skill.isBuiltIn, !skill.isFromPlugin {
                guard await SkillManager.shared.delete(id: skill.id) else {
                    return row(.failed, "Osaurus could not delete the skill.")
                }
            } else {
                gone = true
            }
        case .mcp:
            let providers = MCPProviderManager.shared.configuration.providers
            if let id = receipt.mcpProviderId.flatMap(UUID.init(uuidString:)),
                providers.contains(where: { $0.id == id })
            {
                MCPProviderManager.shared.removeProvider(id: id)
            } else {
                gone = true
            }
        case .harnessRuntime:
            if let id = receipt.harnessRuntimeId.flatMap(UUID.init(uuidString:)),
                HarnessRuntimeStore.shared.runtime(id: id) != nil
            {
                HarnessRuntimeStore.shared.remove(id: id)
                Task { await HarnessSessionManager.shared.closeIdleSessions(runtimeId: id) }
            } else {
                gone = true
            }
        case .setting:
            receipts.removeAll { $0.bundleId == receipt.bundleId && $0.matches(kind: .setting, name: receipt.name) }
            guard let setting = BundleSetting.named(receipt.name) else { return row(.done, nil) }
            return row(
                .done,
                "\(setting.title) stays \(settings.value(of: setting)); removing a bundle does not change "
                    + "its settings back.")
        }
        receipts.removeAll { $0.bundleId == receipt.bundleId && $0.matches(kind: receipt.kind, name: receipt.name) }
        removed.insert(Self.removalKey(receipt.kind, receipt.name))
        return row(.done, gone ? "Already removed in Osaurus." : nil)
    }

    // MARK: - Launch notice

    private func announce(_ results: [ImportResult]) {
        let items = results.flatMap(\.items)
        guard !items.isEmpty else { return }
        let agents = items.filter {
            $0.kind == .agent && $0.action != .remove && ($0.status == .done || $0.status == .needsUserAction)
        }.map(\.name)
        let failed = items.filter { $0.status == .failed }
        let unfinished = items.filter { $0.status == .needsUserAction }
        let receipts = ImportQueue.loadReceipts()
        let bundles = Array(
            Set(results.map { result in
                receipts.first { $0.bundleId == result.bundleId }?.bundleName ?? result.bundleId
            })
        ).sorted()
        let source = L("From \(bundles.joined(separator: ", "))")
        if failed.isEmpty && unfinished.isEmpty {
            guard !agents.isEmpty else { return }
            ToastManager.shared.success(
                agents.count == 1 ? L("Agent ready") : L("Agents ready"),
                message: agents.joined(separator: ", ") + " · " + source)
        } else {
            var parts: [String] = [source]
            if !agents.isEmpty { parts.append(L("Added \(agents.joined(separator: ", "))")) }
            if !unfinished.isEmpty {
                parts.append(L("\(unfinished.map(\.name).joined(separator: ", ")) need setup"))
            }
            if !failed.isEmpty {
                parts.append(L("\(failed.map(\.name).joined(separator: ", ")) could not be installed"))
            }
            ToastManager.shared.warning(L("Bundle import finished with issues"), message: parts.joined(separator: " · "))
        }
    }
}
