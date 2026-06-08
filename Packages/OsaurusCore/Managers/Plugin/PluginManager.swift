//
//  PluginManager.swift
//  osaurus
//
//  Manages loading and lifecycle of external plugins.
//

import Foundation
import Darwin
import Combine
import CryptoKit
import Security
import OsaurusRepository

@MainActor
final class PluginManager {
    static let shared = PluginManager()

    struct LoadedPlugin: @unchecked Sendable {
        let plugin: ExternalPlugin
        let handle: UnsafeMutableRawPointer
        let tools: [ExternalTool]
        let skills: [Skill]
        let routes: [PluginManifest.RouteSpec]
        let webConfig: PluginManifest.WebSpec?
        let readmePath: URL?
        let changelogPath: URL?
    }

    /// Represents a plugin that failed to load
    struct FailedPlugin: Sendable {
        let pluginId: String
        let error: String
        /// Last manifest the host successfully decoded for this plugin
        /// before the failure. Populated for failures that happen AFTER
        /// `get_manifest` (compatibility check, web/route conflict,
        /// first-delivery handshake), nil for failures that happen
        /// before (dlopen / init / parse manifest / quarantine). Lets
        /// the agent detail view filter failed plugins the same way it
        /// filters loaded ones (routes / secrets / instructions /
        /// config / web), and surface a meaningful name.
        let lastKnownManifest: PluginManifest?

        init(pluginId: String, error: String, lastKnownManifest: PluginManifest? = nil) {
            self.pluginId = pluginId
            self.error = error
            self.lastKnownManifest = lastKnownManifest
        }
    }

    /// Error type for plugin loading failures
    struct PluginLoadError: Error, CustomStringConvertible, Sendable {
        let message: String
        /// Manifest that was successfully decoded before the failure was
        /// raised, if any. Surfaced through `FailedPlugin.lastKnownManifest`
        /// so the UI can show the plugin's display name and filter it the
        /// same way loaded plugins are filtered.
        let manifest: PluginManifest?
        var description: String { message }

        init(message: String, manifest: PluginManifest? = nil) {
            self.message = message
            self.manifest = manifest
        }

        static let consentRequiredPrefix = "consent_required:"
    }

    private(set) var plugins: [LoadedPlugin] = []
    private var loadedPluginPaths: Set<String> = []

    /// Plugins that failed to load, keyed by plugin ID
    private(set) var failedPlugins: [String: FailedPlugin] = [:]

    private var tunnelObserver: AnyCancellable?

    /// NotificationCenter tokens for `.agentAdded` / `.agentRemoved`. Held for
    /// the lifetime of the singleton so the closures stay live.
    private var agentLifecycleObservers: [NSObjectProtocol] = []

    /// Last `tunnel_url` value we pushed to each `(pluginId, agentId)` pair.
    /// Used to dedup `pushTunnelURL` calls *against the host's own delivery
    /// history* rather than against the keychain entry — which the plugin
    /// can mutate via `config_delete`, defeating the dedup and causing
    /// repeated webhook setups during launch races. The inner Optional
    /// stores `String?` (nil = "tunnel down was the last thing we pushed").
    /// Internal so unit tests can inspect the cache structure.
    var lastPushedTunnelURL: [String: [UUID: String?]] = [:]

    /// Last `AgentRelayStatus` per agent, so `handleTunnelStatusChange`
    /// can detect `non-.connected -> .connected(U)` reconnect
    /// transitions (the agent's URL is usually unchanged across the
    /// gap, so value-equality dedup would otherwise swallow the
    /// redelivery and leave Telegram-style webhooks stale).
    /// Internal for unit tests.
    var lastObservedTunnelStatus: [UUID: AgentRelayStatus] = [:]

    /// True when `status` is `.connected(_)`.
    static func isConnectedStatus(_ status: AgentRelayStatus?) -> Bool {
        guard let status else { return false }
        if case .connected = status { return true }
        return false
    }

    /// Relay-reconnect signal: `non-.connected -> .connected(_)` for
    /// an agent we've already observed. First-ever observations
    /// (`from == nil`) are NOT reconnects — `runFirstDeliverySweep`
    /// already pushed the launch snapshot.
    static func isReconnectTransition(
        from old: AgentRelayStatus?,
        to new: AgentRelayStatus
    ) -> Bool {
        guard old != nil else { return false }
        return !isConnectedStatus(old) && isConnectedStatus(new)
    }

    /// Pure decision function for `handleTunnelStatusChange`: returns
    /// true when the host should push `url` to `(pluginId, agentId)`,
    /// false when the prior push was identical and we should dedup.
    /// Extracted as a static helper so the dedup contract can be unit
    /// tested without a real plugin.
    static func shouldPushTunnelURL(
        url: String?,
        pluginId: String,
        agentId: UUID,
        cache: [String: [UUID: String?]]
    ) -> Bool {
        let lastPushed: String? = cache[pluginId]?[agentId] ?? nil
        return lastPushed != url
    }

    /// Serializes reload operations to prevent concurrent `performPluginScan`
    /// calls from overwriting and deallocating each other's host contexts.
    private var activeReloadTask: Task<Void, Never>?

    private init() {}

    /// Returns the load error for a specific plugin, if any
    func loadError(for pluginId: String) -> String? {
        return failedPlugins[pluginId]?.error
    }

    /// Look up a loaded plugin by its ID (used by HTTP route dispatch)
    func loadedPlugin(for pluginId: String) -> LoadedPlugin? {
        return plugins.first { $0.plugin.id == pluginId }
    }

    #if DEBUG
        /// Test-only: insert a pre-built `LoadedPlugin` so regression tests
        /// can exercise the `BackgroundTaskManager` → `emitPluginEvent` →
        /// `ExternalPlugin.notifyTaskEvent` chain without going through
        /// dlopen + the full scan pipeline. The matched `removeLoadedPluginForTesting`
        /// must be called in `defer` so the singleton is left clean.
        func injectLoadedPluginForTesting(_ loaded: LoadedPlugin) {
            plugins.append(loaded)
        }

        /// Test-only: matched cleanup for `injectLoadedPluginForTesting`.
        /// Removes the plugin without touching `ToolRegistry` / `SkillManager`
        /// (the fake plugin never registered with either).
        ///
        /// IMPORTANT: synchronously drains the plugin's per-task event
        /// queues and config event queue BEFORE removing it from `plugins`.
        /// Tests that pass a `TaskEventRecorder` (or any other captured
        /// state) through the opaque `ctx` pointer release their
        /// `Unmanaged.passRetained(...)` retain in the same `defer` block —
        /// any `notifyTaskEvent` callback still queued on a per-task
        /// dispatch queue would otherwise fire AFTER the recorder is
        /// deallocated and segfault the entire xctest process. This is
        /// the regression that surfaced as the "100+ tests crashed with
        /// signal segv" pattern in CI runs 25738325529 (PR #1066) and
        /// 25742705850 (PR #1068); see `ExternalPlugin
        /// .drainEventQueuesForTesting()` for the full root-cause writeup.
        func removeLoadedPluginForTesting(pluginId: String) {
            if let plugin = plugins.first(where: { $0.plugin.id == pluginId })?.plugin {
                plugin.drainEventQueuesForTesting()
            }
            plugins.removeAll { $0.plugin.id == pluginId }
        }
    #endif

    // MARK: - Loading

    /// Result of heavy plugin scanning performed on a background thread.
    private struct PluginScanResult: @unchecked Sendable {
        let allURLs: [URL]
        let verificationFailures: [String: String]
        let loadResults: [(url: URL, result: Result<LoadedPlugin, PluginLoadError>)]
    }

    /// Scans the tools directory and loads all plugins found.
    /// Heavy work (filesystem scanning, SHA256 verification, dlopen) runs on a background thread.
    /// When `forceReload` is true, all existing plugins are unloaded first so every
    /// dylib is re-opened from disk (used by the `toolsReload` notification for hot-reload).
    func loadAll(forceReload: Bool = false) async {
        if let task = activeReloadTask {
            await task.value
            if !forceReload { return }
            // If another task was queued by a concurrent caller while we waited,
            // just wait for that one to finish instead of starting a third.
            if let newTask = activeReloadTask {
                await newTask.value
                return
            }
        }

        let task = Task {
            await _loadAll(forceReload: forceReload)
        }
        activeReloadTask = task
        await task.value

        if activeReloadTask == task {
            activeReloadTask = nil
        }
    }

    private func _loadAll(forceReload: Bool = false) async {
        Self.ensureToolsDirectoryExists()

        // Clear previous failures before scanning
        failedPlugins.removeAll()

        if forceReload {
            for loaded in plugins {
                ToolRegistry.shared.unregister(names: loaded.tools.map { $0.name })
                if !loaded.skills.isEmpty {
                    await SkillManager.shared.unregisterPluginSkills(pluginId: loaded.plugin.id)
                }
                await loaded.plugin.shutdown()
                PluginHostContext.getContext(for: loaded.plugin.id)?.teardown()
                lastPushedTunnelURL.removeValue(forKey: loaded.plugin.id)
                // Do not dlclose here. The plugin is already unloaded from the
                // registry, but dlclose on macOS ARM64 causes stale PAC
                // signatures if the same path is ever reloaded.
            }
            plugins.removeAll()
            loadedPluginPaths.removeAll()
        }

        // Capture current state needed for background work
        let alreadyLoadedPaths = self.loadedPluginPaths

        // Heavy work on background thread: filesystem scan, SHA256 verify, dlopen, plugin init
        let scanResult = await Task.detached(priority: .userInitiated) {
            Self.performPluginScan(alreadyLoadedPaths: alreadyLoadedPaths)
        }.value

        // --- Everything below runs on main thread (registry & state mutations) ---

        for (pluginId, error) in scanResult.verificationFailures {
            failedPlugins[pluginId] = FailedPlugin(pluginId: pluginId, error: error)
        }

        let currentPaths = Set(scanResult.allURLs.map { $0.path })

        // Unload removed plugins
        var remaining: [LoadedPlugin] = []
        var removedSomething = false

        for loaded in plugins {
            if currentPaths.contains(loaded.plugin.bundlePath) {
                remaining.append(loaded)
            } else {
                ToolRegistry.shared.unregister(names: loaded.tools.map { $0.name })
                if !loaded.skills.isEmpty {
                    await SkillManager.shared.unregisterPluginSkills(pluginId: loaded.plugin.id)
                }
                await loaded.plugin.shutdown()
                PluginHostContext.getContext(for: loaded.plugin.id)?.teardown()
                lastPushedTunnelURL.removeValue(forKey: loaded.plugin.id)
                // Do not dlclose here. The plugin is already unloaded from the
                // registry, but dlclose on macOS ARM64 causes stale PAC
                // signatures if the same path is ever reloaded.
                loadedPluginPaths.remove(loaded.plugin.bundlePath)
                removedSomething = true
            }
        }
        plugins = remaining

        // Register newly loaded plugins
        var loadedNew = false
        for entry in scanResult.loadResults {
            switch entry.result {
            case .success(let loaded):
                plugins.append(loaded)
                loadedPluginPaths.insert(entry.url.path)
                loadedNew = true

                // Register tools
                for tool in loaded.tools {
                    ToolRegistry.shared.registerPluginTool(tool)
                }

                // Register plugin skills
                for skill in loaded.skills {
                    await SkillManager.shared.registerPluginSkill(skill)
                }

                // Clear any previous failure for this plugin
                failedPlugins.removeValue(forKey: loaded.plugin.id)

            case .failure(let error):
                let pluginId = Self.extractPluginId(from: entry.url)
                failedPlugins[pluginId] = FailedPlugin(
                    pluginId: pluginId,
                    error: error.message,
                    lastKnownManifest: error.manifest
                )
            }
        }

        if loadedNew || removedSomething || !failedPlugins.isEmpty {
            NotificationCenter.default.post(name: .toolsListChanged, object: nil)
        }

        observeTunnelStatus()
        // Per-plugin first-delivery sweep, each step bracketed by the
        // `.currently_loading` marker. A SIGABRT inside the plugin's
        // `on_config_changed` (e.g. misaligned ABI mirror calling
        // `host->free_string` on a non-malloc pointer) leaves the marker
        // on disk; the next launch reads it via `promoteStaleLoadingMarker`
        // and quarantines the plugin instead of crash-looping the host.
        runFirstDeliverySweep(from: scanResult)
    }

    /// Synthetic config key the host pushes once per plugin at load time
    /// to exercise the plugin's view of `host->get_active_agent_id` +
    /// `host->free_string` round-trip BEFORE the first real config push.
    /// Plugins should treat any unknown key as a no-op (per
    /// `osaurus_plugin.h`), but most plugins call `host->get_active_agent_id`
    /// at the top of `on_config_changed` to resolve the active agent —
    /// so a misaligned `osr_host_api` mirror trips the libmalloc abort
    /// here, INSIDE the loading marker, which then quarantines the
    /// plugin on the next launch instead of crash-looping.
    ///
    /// Plugins that explicitly want to opt out of the probe can match
    /// `key == "__osaurus_abi_probe__"` and early-return; the value is
    /// always a fresh UUID with no semantic meaning. Documented under
    /// `docs/plugins/HOST_API.md` so authors know to ignore it.
    ///
    /// `nonisolated` because the constant is a literal string — safe
    /// to read from any actor / queue, including plugin-author tests
    /// that match against it from a non-MainActor context.
    nonisolated static let abiProbeKey = "__osaurus_abi_probe__"

    /// Per-plugin first-delivery sweep. The synthetic ABI probe is
    /// delivered SYNCHRONOUSLY inside a `.currently_loading` marker so
    /// that a misaligned `osr_host_api` mirror — the production
    /// crash-loop signature where `host->free_string` resolves to the
    /// wrong slot and `libc free()` aborts on a non-malloc pointer —
    /// quarantines the plugin on the next launch instead of crash-
    /// looping the host. The real per-agent config snapshot and the
    /// relay tunnel URL push run AFTER the probe via the existing
    /// async path so a plugin's expensive `on_config_changed` work
    /// (Telegram `setupWebhook`, OAuth refresh, etc.) does not block
    /// the launch sequence.
    ///
    /// The probe is fast (a single `(__osaurus_abi_probe__, <UUID>)`
    /// pair through the plugin's serial `configEventQueue`) and runs
    /// the same code path the first real config push would: top of
    /// `on_config_changed` → `host->get_active_agent_id()` →
    /// `host->free_string(ptr)`. Plugins that resolve the agent at
    /// the top of `on_config_changed` (the documented pattern) will
    /// trip the misalignment here. Plugins that short-circuit unknown
    /// keys before the host call avoid the probe but also avoid the
    /// production crash signature, so the trade-off is acceptable.
    ///
    /// Sequenced per plugin (not interleaved) so the marker file —
    /// which holds at most one plugin id at a time — always reflects
    /// the plugin currently inside the danger zone.
    private func runFirstDeliverySweep(from scanResult: PluginScanResult) {
        let agents = AgentManager.shared.agents
        let statuses = RelayTunnelManager.shared.agentStatuses

        for entry in scanResult.loadResults {
            guard case .success(let loaded) = entry.result else { continue }

            let pluginId = loaded.plugin.id
            Self.writeLoadingMarker(pluginId: pluginId)
            // Deliberately no `defer`: the marker must persist on the
            // SIGABRT path. It is cleared only after the probe returns
            // cleanly below.
            runAbiHandshakeProbe(loaded: loaded, agentId: agents.first?.id ?? Agent.defaultId)
            Self.clearLoadingMarker()

            // Real per-agent config + tunnel URL pushes resume the
            // existing async fire-and-forget path. The probe above
            // already exercised the misalignment-prone host call
            // pattern, so this fan-out preserves perf without giving
            // up the crash-loop guard.
            //
            // Resolve and deliver the per-agent config off the main
            // actor: the secret reads behind it round-trip to the
            // authentication daemon over blocking XPC, which can stall
            // the main thread for seconds at launch. The plugin's
            // `on_config_changed` already runs on its own serial queue,
            // so nothing on this path needs the main thread.
            let agentIds = agents.map(\.id)
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                for agentId in agentIds {
                    self.deliverInitialConfig(to: loaded, agentId: agentId)
                }
            }

            if !loaded.routes.isEmpty {
                for agent in agents {
                    guard case .connected(let url) = statuses[agent.id] else { continue }
                    pushTunnelURL(url, to: loaded, agentId: agent.id)
                }
            }
        }
    }

    /// One-shot synthetic `on_config_changed` push that exercises the
    /// plugin's view of the host vtable on the same code path the first
    /// real config push would take. The plugin's body is invoked via
    /// `notifyConfigBatchSync` so the call returns inside the loading
    /// marker window — a SIGABRT here writes the quarantine marker
    /// instead of crash-looping the host on every subsequent launch.
    ///
    /// No-op for v1 plugins (no `on_config_changed` slot to dispatch to).
    private func runAbiHandshakeProbe(loaded: LoadedPlugin, agentId: UUID) {
        guard loaded.plugin.abiVersion >= 2 else { return }
        loaded.plugin.notifyConfigBatchSync(
            [(key: Self.abiProbeKey, value: UUID().uuidString)],
            agentId: agentId
        )
    }

    /// Push the resolved config for `(plugin, agent)` to the plugin via
    /// `notifyConfigBatch`. Reads agent-scoped secrets, falls back to
    /// per-key keychain entries and field defaults, and filters by the
    /// plugin's declared config field keys. No-op when the plugin has no
    /// config spec, no host context, or yields zero changes.
    ///
    /// `sync == true` routes through `notifyConfigBatchSync` so the call
    /// returns inside the load-time `.currently_loading` marker window
    /// — used by `runFirstDeliverySweep` so a plugin abort during initial
    /// delivery quarantines the plugin on the next launch instead of
    /// crash-looping the host. Runtime callers (agent added,
    /// PluginConfigView save) leave `sync == false` to keep the existing
    /// fire-and-forget semantics.
    nonisolated private func deliverInitialConfig(
        to loaded: LoadedPlugin,
        agentId: UUID,
        sync: Bool = false,
        force: Bool = false
    ) {
        let pluginId = loaded.plugin.id
        guard let configSpec = loaded.plugin.manifest.capabilities.config,
            PluginHostContext.getContext(for: pluginId) != nil
        else { return }

        let allFieldKeys = Set(configSpec.sections.flatMap { $0.fields.map { $0.key } })
        var values = ToolSecretsKeychain.getAllSecrets(for: pluginId, agentId: agentId)

        for section in configSpec.sections {
            for field in section.fields {
                if values[field.key] == nil, field.type != .readonly, field.type != .status,
                    let val = ToolSecretsKeychain.getSecret(id: field.key, for: pluginId, agentId: agentId)
                {
                    values[field.key] = val
                }
                if values[field.key] == nil, let def = field.default {
                    values[field.key] = def.stringValue
                }
                if let connKey = field.connected_when, values[connKey] == nil,
                    let val = ToolSecretsKeychain.getSecret(id: connKey, for: pluginId, agentId: agentId)
                {
                    values[connKey] = val
                }
            }
        }

        let changes: [(key: String, value: String)] = values.compactMap { key, value in
            allFieldKeys.contains(key) ? (key: key, value: value) : nil
        }
        guard !changes.isEmpty else { return }
        if sync {
            loaded.plugin.notifyConfigBatchSync(changes, agentId: agentId, force: force)
        } else {
            loaded.plugin.notifyConfigBatch(changes, agentId: agentId, force: force)
        }
    }

    // MARK: - Tunnel URL Propagation

    /// Observes relay tunnel status changes and propagates the tunnel URL
    /// to plugins that declare routes, so they can register webhooks with
    /// external services (e.g. Telegram). Also subscribes to agent
    /// lifecycle notifications so newly added / removed agents trigger a
    /// per-agent config push (or webhook deregister) on every loaded plugin.
    private func observeTunnelStatus() {
        guard tunnelObserver == nil else { return }

        // Seed before wiring the sink so the first delivery on launch
        // hits the no-op first-observation branch in
        // `isReconnectTransition` instead of force-redelivering work
        // `runFirstDeliverySweep` just performed synchronously.
        lastObservedTunnelStatus = RelayTunnelManager.shared.agentStatuses

        tunnelObserver = RelayTunnelManager.shared.$agentStatuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statuses in
                self?.handleTunnelStatusChange(statuses)
            }

        // Idempotent — the only writer is `_loadAll`, which only ever
        // calls this once because of the `tunnelObserver == nil` guard
        // above. The same guard protects the agent observers.
        if agentLifecycleObservers.isEmpty {
            agentLifecycleObservers.append(
                subscribeAgentLifecycle(.agentAdded) { $0.handleAgentAdded($1) }
            )
            agentLifecycleObservers.append(
                subscribeAgentLifecycle(.agentRemoved) { $0.handleAgentRemoved($1) }
            )
        }
    }

    /// Wires a `NotificationCenter` observer for `name` that decodes
    /// `userInfo["agentId"]` and hops to the main actor before invoking
    /// `handler` against the live `PluginManager` instance. Collapses
    /// the two near-identical observer blocks for `.agentAdded` /
    /// `.agentRemoved` and keeps both behind a single weak self capture.
    private func subscribeAgentLifecycle(
        _ name: Notification.Name,
        _ handler: @escaping @MainActor (PluginManager, UUID) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self, let agentId = note.userInfo?["agentId"] as? UUID else { return }
            Task { @MainActor in handler(self, agentId) }
        }
    }

    /// Deliver the full per-agent config + current tunnel URL to every
    /// loaded plugin for a freshly added agent. Mirrors what `_loadAll`
    /// does at startup, scoped to a single agent.
    private func handleAgentAdded(_ agentId: UUID) {
        deliverFullAgentSnapshot(
            agentId: agentId,
            status: RelayTunnelManager.shared.agentStatuses[agentId],
            force: false
        )
    }

    /// Tear down per-agent state on every loaded plugin when an agent is
    /// deleted: push `tunnel_url=""` so plugins can deregister their
    /// webhooks. Per-agent keychain secrets are swept by
    /// `AgentManager.delete(id:)` itself before this handler runs.
    private func handleAgentRemoved(_ agentId: UUID) {
        for loaded in plugins where !loaded.routes.isEmpty {
            pushTunnelURL(nil, to: loaded, agentId: agentId)
        }
        // Drop the dedup entry for this agent across every plugin slot
        // so a future agent re-using this UUID (extremely unlikely, but
        // possible if a user restores from backup) gets a fresh push.
        for pluginId in lastPushedTunnelURL.keys {
            lastPushedTunnelURL[pluginId]?.removeValue(forKey: agentId)
        }
    }

    private func handleTunnelStatusChange(_ statuses: [UUID: AgentRelayStatus]) {
        for (agentId, status) in statuses {
            let oldStatus = lastObservedTunnelStatus[agentId]
            lastObservedTunnelStatus[agentId] = status

            // Reconnect: force-redeliver the full per-agent snapshot
            // so plugins re-assert upstream registrations (Telegram
            // `setWebhook`, OAuth refresh) even when the URL is
            // unchanged across the disconnect window.
            if Self.isReconnectTransition(from: oldStatus, to: status) {
                deliverFullAgentSnapshot(agentId: agentId, status: status, force: true)
                continue
            }

            for loaded in plugins where !loaded.routes.isEmpty {
                let tunnelURL: String? = if case .connected(let url) = status { url } else { nil }

                // Dedup against the value we last pushed for this
                // `(plugin, agent)` pair, NOT the keychain entry — the
                // plugin can mutate the keychain via `config_delete` and
                // we still need to deliver the next status change.
                guard
                    Self.shouldPushTunnelURL(
                        url: tunnelURL,
                        pluginId: loaded.plugin.id,
                        agentId: agentId,
                        cache: lastPushedTunnelURL
                    )
                else { continue }

                pushTunnelURL(tunnelURL, to: loaded, agentId: agentId)
            }
        }
    }

    /// Push the full per-agent config snapshot to every loaded plugin
    /// and (if `status` is connected) the tunnel URL to plugins that
    /// declare routes. Shared body for `handleAgentAdded` (force=false)
    /// and the relay-reconnect branch in `handleTunnelStatusChange`
    /// (force=true). With `force: true` both dedup layers are bypassed
    /// so plugins re-fire `on_config_changed` on identical values —
    /// documented under `docs/plugins/HOST_API.md`; plugin authors
    /// must keep `on_config_changed` idempotent for repeat values.
    private func deliverFullAgentSnapshot(
        agentId: UUID,
        status: AgentRelayStatus?,
        force: Bool
    ) {
        // Resolve and deliver each plugin's config off the main actor;
        // the secret reads behind it block on authentication-daemon XPC
        // and must not stall the main thread when an agent is added or a
        // relay reconnects.
        let loadedPlugins = plugins
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            for loaded in loadedPlugins {
                self.deliverInitialConfig(to: loaded, agentId: agentId, force: force)
            }
        }
        guard case .connected(let url) = status else { return }
        for loaded in plugins where !loaded.routes.isEmpty {
            pushTunnelURL(url, to: loaded, agentId: agentId, force: force)
        }
    }

    /// `sync == true` routes through `notifyConfigBatchSync` so the call
    /// returns inside the load-time loading marker window, matching the
    /// crash-loop-guard contract `runFirstDeliverySweep` relies on.
    /// Runtime callers (`handleAgentAdded`, `handleTunnelStatusChange`)
    /// leave `sync == false` to preserve the existing fire-and-forget
    /// semantics.
    private func pushTunnelURL(
        _ url: String?,
        to loaded: LoadedPlugin,
        agentId: UUID,
        sync: Bool = false,
        force: Bool = false
    ) {
        let pluginId = loaded.plugin.id

        if let url {
            ToolSecretsKeychain.saveSecret(url, id: "tunnel_url", for: pluginId, agentId: agentId)
        } else {
            ToolSecretsKeychain.deleteSecret(id: "tunnel_url", for: pluginId, agentId: agentId)
        }

        // Record the value we pushed so `handleTunnelStatusChange` can
        // dedup. Setting `[agentId] = nil` removes the entry; that's
        // intentional — an absent entry is treated as "last pushed = nil"
        // by the dedup, which preserves correctness.
        lastPushedTunnelURL[pluginId, default: [:]][agentId] = url

        NotificationCenter.default.post(
            name: .pluginConfigDidChange,
            object: nil,
            userInfo: ["pluginId": pluginId, "key": "tunnel_url", "value": url ?? ""]
        )

        if sync {
            loaded.plugin.notifyConfigBatchSync(
                [(key: "tunnel_url", value: url ?? "")],
                agentId: agentId,
                force: force
            )
        } else {
            loaded.plugin.notifyConfigChanged(
                key: "tunnel_url",
                value: url ?? "",
                agentId: agentId,
                force: force
            )
        }
    }

    // MARK: - Artifact Handler Notifications

    /// Notifies all plugins that declared `artifact_handler: true` about a shared artifact.
    /// Invocations run concurrently but are awaited so they complete before the caller
    /// returns -- this keeps the originating request context (e.g. active chat) alive.
    func notifyArtifactHandlers(artifact: SharedArtifact) async {
        let payload = PluginHostContext.serializeArtifactEvent(artifact: artifact)
        let handlers = plugins.filter {
            $0.plugin.manifest.capabilities.artifact_handler == true && $0.plugin.abiVersion >= 2
        }
        guard !handlers.isEmpty else {
            NSLog(
                "[PluginManager] No artifact handler plugins for '%@' (%d loaded)",
                artifact.filename,
                plugins.count
            )
            return
        }

        await withTaskGroup(of: Void.self) { group in
            for loaded in handlers {
                let pluginId = loaded.plugin.id
                group.addTask {
                    do {
                        _ = try await loaded.plugin.invoke(
                            type: "artifact",
                            id: "share",
                            payload: payload
                        )
                        NSLog(
                            "[PluginManager] Artifact '%@' delivered to '%@'",
                            artifact.filename,
                            pluginId
                        )
                    } catch {
                        NSLog(
                            "[PluginManager] Artifact '%@' delivery to '%@' failed: %@",
                            artifact.filename,
                            pluginId,
                            error.localizedDescription
                        )
                    }
                }
            }
        }
    }

    // MARK: - Background Scanning & Loading (nonisolated)

    /// Performs the heavy plugin scanning work on a background thread.
    /// Scans filesystem for dylibs, verifies checksums, loads plugins via dlopen.
    nonisolated private static func performPluginScan(
        alreadyLoadedPaths: Set<String>
    ) -> PluginScanResult {
        let (urls, verificationFailures) = toolsDirectoryURLsWithFailures()

        var loadResults: [(url: URL, result: Result<LoadedPlugin, PluginLoadError>)] = []
        for url in urls {
            if alreadyLoadedPaths.contains(url.path) { continue }
            let pluginId = extractPluginId(from: url)
            writeLoadingMarker(pluginId: pluginId)
            let result = loadPluginWithError(at: url)
            clearLoadingMarker()
            loadResults.append((url: url, result: result))
        }

        return PluginScanResult(
            allURLs: urls,
            verificationFailures: verificationFailures,
            loadResults: loadResults
        )
    }

    /// Extracts the plugin ID from a dylib URL path
    /// Expected path: .../Tools/{pluginId}/{version}/plugin.dylib
    nonisolated private static func extractPluginId(from url: URL) -> String {
        // Go up from dylib -> version dir -> plugin dir
        let versionDir = url.deletingLastPathComponent()
        let pluginDir = versionDir.deletingLastPathComponent()
        return pluginDir.lastPathComponent
    }

    // MARK: - Manifest Compatibility Enforcement

    /// Reads the host's `CFBundleShortVersionString` for `min_osaurus`
    /// comparison. Falls back to a sentinel that compares as 0.0.0 so
    /// Returns the empty string when bundle metadata is absent —
    /// `compatibilityFailure` interprets that as "host version
    /// unknown" and fails *open* with a one-shot warning rather than
    /// rejecting every plugin that declares `min_osaurus`. Erroring
    /// closed (the previous behavior) bricked dev builds where
    /// `Bundle.main` is the swiftpm helper or an Xcode build that
    /// only sets `MARKETING_VERSION = 1.0`.
    nonisolated static func currentHostVersionString() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    /// Lenient semver parser for the *host* version. The strict
    /// `SemanticVersion.parse` requires `M.m.p`, but Xcode's default
    /// `MARKETING_VERSION` is often `1.0` (or even `1`). Treat missing
    /// components as zero so `"1.0"` → `1.0.0`, matching how Apple
    /// itself expresses bundle versions. Returns nil only when the
    /// leading component isn't an integer.
    nonisolated static func parseHostVersion(_ s: String) -> SemanticVersion? {
        if let strict = SemanticVersion.parse(s) { return strict }
        let core = s.split(separator: "-", maxSplits: 1).first.map(String.init) ?? s
        let parts = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let major = parts.first.flatMap(Int.init) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let patch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        return SemanticVersion(major: major, minor: minor, patch: patch)
    }

    /// Returns a `PluginLoadError` when the manifest declares a
    /// `min_osaurus` or `min_macos` constraint that the running host
    /// does not satisfy. Returns nil when both constraints are met
    /// (or absent). Unparseable declarations on *either* side are not
    /// treated as a hard failure — we log a one-off warning so the
    /// developer sees it but the plugin still loads. This matters for
    /// dev builds where the host's bundle metadata may be missing or
    /// shaped like `1.0` instead of `1.0.0`. Pure function: takes
    /// injected host / OS versions so unit tests can drive every
    /// branch without touching real bundle metadata.
    nonisolated static func compatibilityFailure(
        manifest: PluginManifest,
        hostVersion: String,
        osVersion: OperatingSystemVersion
    ) -> PluginLoadError? {
        if let minHost = manifest.min_osaurus, !minHost.isEmpty {
            if let required = SemanticVersion.parse(minHost) {
                if let current = parseHostVersion(hostVersion) {
                    if current < required {
                        return PluginLoadError(
                            message:
                                "Plugin \(manifest.plugin_id) requires Osaurus \(required) or later; "
                                + "this host is \(current). Update Osaurus to load this plugin."
                        )
                    }
                } else {
                    // Unknown host version (no bundle metadata, or a
                    // shape we can't make sense of). Fail open so dev
                    // builds aren't blocked, but make it visible.
                    NSLog(
                        "[Osaurus] Cannot enforce min_osaurus='%@' for %@ — host version "
                            + "'%@' is empty or unparseable. Allowing load (dev build?).",
                        minHost,
                        manifest.plugin_id,
                        hostVersion
                    )
                }
            } else {
                NSLog(
                    "[Osaurus] Plugin %@ has unparseable min_osaurus '%@' — ignoring constraint.",
                    manifest.plugin_id,
                    minHost
                )
            }
        }

        if let minOS = manifest.min_macos, !minOS.isEmpty {
            if let required = parseOSVersion(minOS) {
                if !osVersionAtLeast(current: osVersion, required: required) {
                    let req = "\(required.majorVersion).\(required.minorVersion).\(required.patchVersion)"
                    let cur =
                        "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
                    return PluginLoadError(
                        message:
                            "Plugin \(manifest.plugin_id) requires macOS \(req) or later; "
                            + "this Mac is on \(cur). Update macOS to load this plugin."
                    )
                }
            } else {
                NSLog(
                    "[Osaurus] Plugin %@ has unparseable min_macos '%@' — ignoring constraint.",
                    manifest.plugin_id,
                    minOS
                )
            }
        }

        return nil
    }

    /// Parses a "MAJOR[.MINOR[.PATCH]]" macOS version string into an
    /// `OperatingSystemVersion`. Trailing components default to zero,
    /// matching how Apple expresses min-required SDK versions
    /// (`"14"` / `"14.5"` / `"14.5.1"` are all valid). Returns nil
    /// when no leading integer can be parsed.
    nonisolated static func parseOSVersion(_ s: String) -> OperatingSystemVersion? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let major = parts.first.flatMap(Int.init) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let patch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        return OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    /// `OperatingSystemVersion` doesn't conform to `Comparable`, so we
    /// roll a small lexicographic comparison rather than pulling in
    /// `Foundation`'s `isOperatingSystemAtLeast(_:)` which always reads
    /// the live system version (untestable).
    nonisolated static func osVersionAtLeast(
        current: OperatingSystemVersion,
        required: OperatingSystemVersion
    ) -> Bool {
        if current.majorVersion != required.majorVersion {
            return current.majorVersion > required.majorVersion
        }
        if current.minorVersion != required.minorVersion {
            return current.minorVersion > required.minorVersion
        }
        return current.patchVersion >= required.patchVersion
    }

    /// Loads a single plugin from a dylib URL via dlopen + C ABI handshake.
    /// Tries v2 entry point first (with host API injection), then falls back to v1.
    nonisolated private static func loadPluginWithError(at url: URL) -> Result<LoadedPlugin, PluginLoadError> {
        let flags = RTLD_NOW | RTLD_LOCAL
        guard let handle = dlopen(url.path, Int32(flags)) else {
            let errorMsg: String
            if let err = dlerror() {
                errorMsg = "Failed to load library: \(String(cString: err))"
            } else {
                errorMsg = "Failed to load library (unknown error)"
            }
            print("[Osaurus] dlopen failed for \(url.path): \(errorMsg)")
            return .failure(PluginLoadError(message: errorMsg))
        }

        // Try v2 entry point first, then fall back to v1
        let api: osr_plugin_api
        let abiVersion: UInt32
        var hostContext: PluginHostContext?

        if let v2sym = dlsym(handle, "osaurus_plugin_entry_v2") {
            // v2 path: create host context and pass to plugin
            // We need the plugin ID to scope the host context. We'll use the
            // directory name as a preliminary ID, then confirm from the manifest.
            let preliminaryId = extractPluginId(from: url)

            let ctx: PluginHostContext
            do {
                ctx = try PluginHostContext(pluginId: preliminaryId)
            } catch {
                let errorMsg = "Failed to create host context: \(error.localizedDescription)"
                print("[Osaurus] \(errorMsg) for \(url.lastPathComponent)")
                dlclose(handle)
                return .failure(PluginLoadError(message: errorMsg))
            }

            PluginHostContext.currentContext = ctx
            PluginHostContext.setActivePlugin(preliminaryId)
            let hostAPIPtr = ctx.buildHostAPI()
            let entryFn = unsafeBitCast(v2sym, to: osr_plugin_entry_v2_t.self)
            let apiRawPtr = entryFn(UnsafeRawPointer(hostAPIPtr))
            PluginHostContext.clearActivePlugin()
            PluginHostContext.currentContext = nil

            guard let apiRawPtr else {
                let errorMsg = "Plugin v2 entry returned null API"
                print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
                ctx.teardown()
                dlclose(handle)
                return .failure(PluginLoadError(message: errorMsg))
            }

            let apiPtr = apiRawPtr.assumingMemoryBound(to: osr_plugin_api.self)
            api = apiPtr.pointee
            abiVersion = max(api.version, 2)
            hostContext = ctx

            PluginHostContext.setContext(ctx, for: preliminaryId)
            print("[Osaurus] Loaded plugin from \(url.lastPathComponent) (entry=v2, abi=v\(abiVersion))")
        } else if let v1sym = dlsym(handle, "osaurus_plugin_entry") {
            let entryFn = unsafeBitCast(v1sym, to: osr_plugin_entry_t.self)
            guard let apiRawPtr = entryFn() else {
                let errorMsg = "Plugin entry returned null API"
                print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
                dlclose(handle)
                return .failure(PluginLoadError(message: errorMsg))
            }

            let apiPtr = apiRawPtr.assumingMemoryBound(to: osr_plugin_api.self)
            api = apiPtr.pointee
            abiVersion = 1
            print(
                "[Osaurus] Loaded plugin from \(url.lastPathComponent) (entry=v1 legacy). "
                    + "v1 plugins cannot call host APIs. Consider rebuilding against the v3 surface "
                    + "(export osaurus_plugin_entry_v2 with api.version >= 2) for richer functionality."
            )
        } else {
            let errorMsg = "Missing plugin entry point (osaurus_plugin_entry_v2 or osaurus_plugin_entry)"
            print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
            dlclose(handle)
            return .failure(PluginLoadError(message: errorMsg))
        }

        // Initialize Plugin
        guard let initFn = api.`init` else {
            let errorMsg = "Plugin missing init function"
            print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
            hostContext?.teardown()
            dlclose(handle)
            return .failure(PluginLoadError(message: errorMsg))
        }

        if let hostContext {
            PluginHostContext.currentContext = hostContext
            PluginHostContext.setActivePlugin(hostContext.pluginId)
        }
        defer {
            PluginHostContext.clearActivePlugin()
            PluginHostContext.currentContext = nil
        }
        let ctx = initFn()

        guard let ctx else {
            let errorMsg = "Plugin initialization failed"
            print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
            hostContext?.teardown()
            dlclose(handle)
            return .failure(PluginLoadError(message: errorMsg))
        }

        // Get Manifest
        guard let getManifest = api.get_manifest, let jsonPtr = getManifest(ctx) else {
            let errorMsg = "Plugin failed to return manifest"
            print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
            api.destroy?(ctx)
            hostContext?.teardown()
            dlclose(handle)
            return .failure(PluginLoadError(message: errorMsg))
        }
        let jsonString = String(cString: jsonPtr)
        api.free_string?(jsonPtr)

        // Parse Manifest
        guard let data = jsonString.data(using: String.Encoding.utf8),
            let manifest = try? JSONDecoder().decode(PluginManifest.self, from: data)
        else {
            let errorMsg = "Failed to parse plugin manifest"
            print("[Osaurus] \(errorMsg) in \(url.lastPathComponent)")
            api.destroy?(ctx)
            hostContext?.teardown()
            dlclose(handle)
            return .failure(PluginLoadError(message: errorMsg))
        }

        // If the manifest plugin_id differs from the directory-derived ID,
        // re-register the host context under the canonical ID.
        if let hc = hostContext, manifest.plugin_id != hc.pluginId {
            PluginHostContext.rekeyContext(from: hc.pluginId, to: manifest.plugin_id)
        }

        // Enforce manifest-declared compatibility constraints. Authors
        // declare `min_osaurus` and `min_macos` so they can opt into ABI
        // surfaces that older hosts don't have (e.g. the v4
        // `get_active_agent_id` callback). Without enforcement the
        // declarations were purely advisory and the plugin would crash
        // at the first call to a missing slot. Fail the load with a
        // structured message instead — surfaced in `failedPlugins` and
        // visible in the UI.
        if let compatError = compatibilityFailure(
            manifest: manifest,
            hostVersion: currentHostVersionString(),
            osVersion: ProcessInfo.processInfo.operatingSystemVersion
        ) {
            print("[Osaurus] \(compatError.message)")
            api.destroy?(ctx)
            hostContext?.teardown()
            dlclose(handle)
            return .failure(
                PluginLoadError(message: compatError.message, manifest: manifest)
            )
        }

        // Validate that web mount paths don't silently shadow dynamic routes.
        // The runtime checks the static branch first, so any overlap means
        // the plugin's `handle_route` for that path can never fire.
        if let mount = manifest.capabilities.web?.mount,
            let routes = manifest.capabilities.routes
        {
            let normalizedMount = mount.hasPrefix("/") ? mount : "/\(mount)"
            for route in routes {
                let routePath = route.path.hasPrefix("/") ? route.path : "/\(route.path)"
                let isShadowed =
                    routePath == normalizedMount
                    || routePath.hasPrefix(normalizedMount + "/")
                if isShadowed {
                    let errorMsg =
                        "Plugin \(manifest.plugin_id) declares route '\(route.path)' under web mount '\(mount)'; the static web branch would shadow this route. Move the route outside the web mount or remove the web mount overlap."
                    print("[Osaurus] \(errorMsg)")
                    api.destroy?(ctx)
                    hostContext?.teardown()
                    dlclose(handle)
                    return .failure(PluginLoadError(message: errorMsg, manifest: manifest))
                }
            }
        }

        let plugin = ExternalPlugin(
            handle: handle,
            api: api,
            ctx: ctx,
            manifest: manifest,
            path: url.path,
            abiVersion: abiVersion
        )
        let tools = (manifest.capabilities.tools ?? []).map { ExternalTool(plugin: plugin, spec: $0) }
        let skills = loadPluginSkills(from: url, pluginId: manifest.plugin_id)
        let routes = manifest.capabilities.routes ?? []
        let webConfig = manifest.capabilities.web

        let versionDir = url.deletingLastPathComponent()
        let readmePath = resolveDocFile(named: "README.md", in: versionDir)
        let changelogPath = resolveDocFile(named: "CHANGELOG.md", in: versionDir)

        return .success(
            LoadedPlugin(
                plugin: plugin,
                handle: handle,
                tools: tools,
                skills: skills,
                routes: routes,
                webConfig: webConfig,
                readmePath: readmePath,
                changelogPath: changelogPath
            )
        )
    }

    /// Finds a documentation file (case-insensitive) in the plugin's version directory.
    nonisolated private static func resolveDocFile(named filename: String, in directory: URL) -> URL? {
        let path = directory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: path.path) {
            return path
        }
        let lower = directory.appendingPathComponent(filename.lowercased())
        if FileManager.default.fileExists(atPath: lower.path) {
            return lower
        }
        return nil
    }

    /// Scans the plugin install directory for SKILL.md files and parses them into Skills
    nonisolated private static func loadPluginSkills(from dylibURL: URL, pluginId: String) -> [Skill] {
        let versionDir = dylibURL.deletingLastPathComponent()
        let skillsDir = versionDir.appendingPathComponent("skills", isDirectory: true)

        var results: [Skill] = []

        // Check for skills/ directory
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: skillsDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return results
        }

        guard
            let files = try? fm.contentsOfDirectory(
                at: skillsDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return results
        }

        for file in files {
            guard file.lastPathComponent.uppercased().hasSuffix("SKILL.MD") else { continue }
            do {
                let content = try String(contentsOf: file, encoding: .utf8)
                var skill = try Skill.parseAnyFormat(from: content)
                // Set the pluginId to link the skill to its plugin
                skill = Skill(
                    id: skill.id,
                    name: skill.name,
                    description: skill.description,
                    version: skill.version,
                    author: skill.author,
                    category: skill.category,
                    enabled: skill.enabled,
                    instructions: skill.instructions,
                    isBuiltIn: false,
                    createdAt: skill.createdAt,
                    updatedAt: skill.updatedAt,
                    references: skill.references,
                    assets: skill.assets,
                    directoryName: skill.directoryName,
                    pluginId: pluginId
                )
                results.append(skill)
                NSLog("[Osaurus] Loaded skill '\(skill.name)' from plugin \(pluginId)")
            } catch {
                NSLog("[Osaurus] Failed to parse SKILL.md from plugin \(pluginId): \(error)")
            }
        }

        return results
    }

    // MARK: - Consent management

    /// Plugin IDs that failed to load because the user has not yet consented.
    var pluginsAwaitingConsent: [String] {
        failedPlugins.values
            .filter { $0.error.hasPrefix(PluginLoadError.consentRequiredPrefix) }
            .map { $0.pluginId }
    }

    /// Grants user consent for a plugin, allowing it to load on the next scan.
    /// Writes a `.user_consent` marker to the plugin's current version directory.
    func grantConsent(pluginId: String) throws {
        guard let versionDir = Self.resolveCurrentVersionDir(pluginId: pluginId) else {
            throw PluginLoadError(message: "No version directory found for \(pluginId)")
        }
        let consentURL = versionDir.appendingPathComponent(".user_consent", isDirectory: false)
        try Data().write(to: consentURL)
    }

    // MARK: - Tools directory helpers

    /// Resolves the current version directory for a plugin via the "current" symlink
    /// or by picking the highest installed semver.
    nonisolated private static func resolveCurrentVersionDir(pluginId: String) -> URL? {
        let fm = FileManager.default
        let pluginDir = toolsRootDirectory().appendingPathComponent(pluginId, isDirectory: true)
        let currentLink = pluginDir.appendingPathComponent("current", isDirectory: false)

        if let dest = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) {
            return pluginDir.appendingPathComponent(dest, isDirectory: true)
        }
        guard
            let entries = try? fm.contentsOfDirectory(
                at: pluginDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }
        return
            entries
            .compactMap { url -> (SemanticVersion, URL)? in
                guard url.hasDirectoryPath, let v = SemanticVersion.parse(url.lastPathComponent) else { return nil }
                return (v, url)
            }
            .sorted { $0.0 > $1.0 }
            .first?.1
    }

    nonisolated static func toolsRootDirectory() -> URL {
        return ToolsPaths.toolsRootDirectory()
    }

    nonisolated static func ensureToolsDirectoryExists() {
        let root = toolsRootDirectory()
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
    }

    nonisolated static func toolsDirectoryURLs() -> [URL] {
        return toolsDirectoryURLsWithFailures().urls
    }

    // MARK: - Plugin Quarantine

    private nonisolated static func currentlyLoadingURL() -> URL {
        toolsRootDirectory().appendingPathComponent(".currently_loading", isDirectory: false)
    }

    private nonisolated static func quarantineURL() -> URL {
        toolsRootDirectory().appendingPathComponent(".quarantine", isDirectory: false)
    }

    nonisolated static func quarantinedPluginIds() -> Set<String> {
        guard let data = try? Data(contentsOf: quarantineURL()),
            let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(ids)
    }

    private nonisolated static func addToQuarantine(_ pluginId: String) {
        var ids = quarantinedPluginIds()
        ids.insert(pluginId)
        if let data = try? JSONEncoder().encode(Array(ids)) {
            try? data.write(to: quarantineURL())
        }
        NSLog("[Osaurus] Quarantined plugin '%@' after crash during load", pluginId)
    }

    nonisolated static func clearQuarantine() {
        try? FileManager.default.removeItem(at: quarantineURL())
        try? FileManager.default.removeItem(at: currentlyLoadingURL())
    }

    /// Removes a single plugin from the quarantine list. Used by the
    /// per-plugin "Retry" button surfaced in `AgentDetailView` for
    /// failed plugins. Whole-list `clearQuarantine()` would unhide
    /// every other quarantined plugin too, which surprises users who
    /// only intended to retry one.
    nonisolated static func removeFromQuarantine(_ pluginId: String) {
        var ids = quarantinedPluginIds()
        guard ids.remove(pluginId) != nil else { return }
        let url = quarantineURL()
        if ids.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else if let data = try? JSONEncoder().encode(Array(ids)) {
            try? data.write(to: url)
        }
        // Wipe the loading marker too — it's the matched cause for
        // most quarantine entries (a SIGABRT inside init or
        // `on_config_changed`), and leaving it would re-quarantine
        // this plugin on the next launch even though we just cleared.
        try? FileManager.default.removeItem(at: currentlyLoadingURL())
    }

    /// If a `.currently_loading` marker was left behind by a crash during
    /// dlopen/init, quarantine that plugin so it is skipped on future launches.
    private nonisolated static func promoteStaleLoadingMarker() {
        let markerURL = currentlyLoadingURL()
        guard let data = try? Data(contentsOf: markerURL),
            let pluginId = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
            !pluginId.isEmpty
        else { return }
        addToQuarantine(pluginId)
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// Writes the `.currently_loading` marker so that if the plugin
    /// crashes the host inside `runFirstDeliverySweep`, the next launch
    /// can quarantine it. Durability matters here: a SIGABRT may fire
    /// milliseconds after the write, well before the page cache is
    /// naturally flushed. We tmp-write → fsync the bytes → atomic
    /// rename → fsync the parent directory so the marker survives a
    /// hard process abort. Falls back to a plain `Data.write` if the
    /// durable path fails for any reason — partial protection beats
    /// none.
    private nonisolated static func writeLoadingMarker(pluginId: String) {
        let url = currentlyLoadingURL()
        let data = Data(pluginId.utf8)
        let fm = FileManager.default
        let tmpURL = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try data.write(to: tmpURL, options: [.atomic])
            if let handle = try? FileHandle(forUpdating: tmpURL) {
                try? handle.synchronize()
                try? handle.close()
            }
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmpURL)
            } else {
                try fm.moveItem(at: tmpURL, to: url)
            }
            fsyncDirectory(url.deletingLastPathComponent())
        } catch {
            try? data.write(to: url)
        }
    }

    private nonisolated static func clearLoadingMarker() {
        try? FileManager.default.removeItem(at: currentlyLoadingURL())
    }

    /// `fsync()`s the directory containing `url` so a preceding atomic
    /// rename is durable across a hard abort. macOS does not flush
    /// directory metadata implicitly when the contained file is
    /// fsynced, so this needs to be done as a separate step.
    private nonisolated static func fsyncDirectory(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }

    /// Returns dylib URLs to load and a dictionary of verification failures (pluginId -> error message)
    nonisolated static func toolsDirectoryURLsWithFailures() -> (urls: [URL], failures: [String: String]) {
        promoteStaleLoadingMarker()

        let fm = FileManager.default
        let root = toolsRootDirectory()
        var dylibURLs: [URL] = []
        var failures: [String: String] = [:]
        let quarantined = quarantinedPluginIds()

        guard
            let pluginDirs = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return (dylibURLs, failures)
        }

        for pluginDir in pluginDirs where pluginDir.hasDirectoryPath {
            let pluginId = pluginDir.lastPathComponent

            if quarantined.contains(pluginId) {
                // Surfaced verbatim in PluginsView and the AgentsView
                // "Failed" tab — point users at the in-app Retry /
                // Uninstall buttons rather than the legacy
                // `osaurus tools reset` CLI (which unquarantines all
                // failed plugins at once).
                failures[pluginId] =
                    "Plugin quarantined after a crash during load — use the Retry or Uninstall button below to recover."
                continue
            }

            let currentLink = pluginDir.appendingPathComponent("current", isDirectory: false)
            var versionDir: URL?
            if let dest = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) {
                versionDir = pluginDir.appendingPathComponent(dest, isDirectory: true)
            } else {
                // Fallback: pick highest SemVer
                if let entries = try? fm.contentsOfDirectory(
                    at: pluginDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) {
                    let versions: [(SemanticVersion, URL)] = entries.compactMap { url in
                        guard url.hasDirectoryPath else { return nil }
                        guard let v = SemanticVersion.parse(url.lastPathComponent) else { return nil }
                        return (v, url)
                    }
                    versionDir = versions.sorted(by: { $0.0 > $1.0 }).first?.1
                }
            }

            guard let vdir = versionDir else {
                // No valid version directory found
                failures[pluginId] = "No valid version directory found"
                continue
            }

            var foundDylib = false
            if let enumerator = fm.enumerator(
                at: vdir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    if fileURL.pathExtension == "dylib" {
                        foundDylib = true
                        let verifyResult = verifyDylibBeforeLoadWithError(fileURL)
                        switch verifyResult {
                        case .success:
                            dylibURLs.append(fileURL)
                        case .failure(let error):
                            failures[pluginId] = error.message
                        }
                    }
                }
            }

            if !foundDylib {
                failures[pluginId] = "No dylib file found in plugin directory"
            }
        }
        return (dylibURLs, failures)
    }

    /// Verifies a dylib's integrity, code signature (release only), and user consent
    /// before allowing it to load. DEBUG builds skip all verification for dev convenience.
    nonisolated private static func verifyDylibBeforeLoadWithError(_ dylibURL: URL) -> Result<Void, PluginLoadError> {
        #if DEBUG
            return .success(())
        #else
            let fm = FileManager.default
            let versionDir = dylibURL.deletingLastPathComponent()
            let receiptURL = versionDir.appendingPathComponent("receipt.json", isDirectory: false)

            guard fm.fileExists(atPath: receiptURL.path) else {
                return .failure(PluginLoadError(message: "Missing receipt.json - plugin cannot be verified"))
            }

            guard let data = try? Data(contentsOf: receiptURL) else {
                return .failure(PluginLoadError(message: "Failed to read receipt.json"))
            }

            guard let receipt = try? JSONDecoder().decode(PluginReceipt.self, from: data) else {
                return .failure(PluginLoadError(message: "Failed to parse receipt.json"))
            }

            guard let dylibData = try? Data(contentsOf: dylibURL) else {
                return .failure(PluginLoadError(message: "Failed to read plugin library file"))
            }

            let digest = CryptoKit.SHA256.hash(data: dylibData)
            let sha = Data(digest).map { String(format: "%02x", $0) }.joined()

            if sha.lowercased() != receipt.dylib_sha256.lowercased() {
                return .failure(
                    PluginLoadError(
                        message: "Checksum verification failed - plugin file may be corrupted or tampered with"
                    )
                )
            }

            if let codesignError = verifyCodeSignature(of: dylibURL) {
                return .failure(codesignError)
            }

            let consentURL = versionDir.appendingPathComponent(".user_consent", isDirectory: false)
            guard fm.fileExists(atPath: consentURL.path) else {
                return .failure(
                    PluginLoadError(
                        message: "\(PluginLoadError.consentRequiredPrefix) Plugin has not been approved for loading"
                    )
                )
            }

            return .success(())
        #endif
    }

    /// Checks the Apple code signature of a dylib using the Security framework.
    /// Returns nil on success or a PluginLoadError describing the failure.
    nonisolated private static func verifyCodeSignature(of url: URL) -> PluginLoadError? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            return PluginLoadError(
                message: "Failed to create code reference for signature verification (OSStatus \(createStatus))"
            )
        }

        let checkStatus = SecStaticCodeCheckValidity(code, SecCSFlags(), nil)
        guard checkStatus == errSecSuccess else {
            return PluginLoadError(
                message:
                    "Plugin code signature is invalid or missing - plugins must be signed with a Developer ID (OSStatus \(checkStatus))"
            )
        }

        return nil
    }
}
