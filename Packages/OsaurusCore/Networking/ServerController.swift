//
//  ServerController.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Combine
import Darwin
import Foundation
@preconcurrency import MLXLMCommon
import NIOCore
import NIOHTTP1
import NIOPosix

/// Main controller responsible for managing the server lifecycle
@MainActor
final class ServerController: ObservableObject {
    // MARK: - Published Properties

    @Published var isRunning: Bool = false
    @Published var lastErrorMessage: String?
    @Published var serverHealth: ServerHealth = .stopped
    @Published var localNetworkAddress: String = "127.0.0.1"
    @Published var configuration: ServerConfiguration = .default
    /// Canonical vmlx runtime settings (network/cache/concurrency/etc.).
    /// The Server → Settings tab edits this; `configuration` is
    /// projected from it on every save so the NIO socket layer keeps
    /// working unchanged.
    @Published var runtimeSettings: VMLXServerRuntimeSettings = .init()
    @Published var activeRequestCount: Int = 0
    @Published var isRestarting: Bool = false

    // Provide shared access to configuration for non-UI callers
    nonisolated static func sharedConfiguration() async -> ServerConfiguration? {
        await MainActor.run { [weak shared = ServerControllerHolder.shared.controller] in
            shared?.configuration
        }
    }

    /// Agent-detail views are not constructed with the Server environment
    /// object. Route their explicit Spawn fan-out edits through the live
    /// controller so persistence, RuntimeConfig invalidation, and every open
    /// Server / Spawn settings surface observe one atomic value.
    static func applyAgentSpawnBatchLimit(_ requested: Int) async {
        let normalized = SpawnBatchConcurrencyContract.normalized(requested)
        guard let controller = ServerControllerHolder.shared.controller else {
            var settings = ServerRuntimeSettingsStore.snapshot()
            settings.concurrency.maxConcurrentSequences = normalized
            ServerRuntimeSettingsStore.save(settings)
            SubagentConfigurationStore.mutate { configuration in
                configuration.budgets.maxParallelSpawns = normalized
            }
            return
        }
        await controller.applySpawnBatchLimit(normalized)
    }

    /// Convenience property for accessing port
    var port: Int {
        get { configuration.port }
        set { configuration.port = newValue }
    }

    // MARK: - Private Properties

    private var serverActor: OsaurusServer?
    private var agentsCancellable: AnyCancellable?
    private var runtimeSettingsCancellable: AnyCancellable?

    /// Flipped once `applicationDidFinishLaunching` finishes its server
    /// wiring. The Bonjour-expose Combine sink consults this so it never
    /// triggers a `restartServer()` while the launch sequence is still
    /// bringing the server up (mid-launch server churn — see hang audit).
    private var isLaunchComplete = false

    // Singleton holder to allow async access to the current controller instance when injected as EnvironmentObject
    @MainActor
    private struct ServerControllerHolder {
        static var shared = ServerControllerHolder()
        weak var controller: ServerController?
        private init() {}
    }

    // MARK: - Generation Activity Signals (nonisolated for low overhead cross-actor calls)
    nonisolated static func signalGenerationStart() {
        Task { @MainActor in
            if let controller = ServerControllerHolder.shared.controller {
                controller.activeRequestCount &+= 1
            }
        }
    }

    nonisolated static func signalGenerationEnd() {
        Task { @MainActor in
            if let controller = ServerControllerHolder.shared.controller {
                controller.activeRequestCount = max(0, controller.activeRequestCount - 1)
            }
        }
    }

    // MARK: - Public Methods

    /// Marks launch as complete. Called by the AppDelegate at the end of
    /// `applicationDidFinishLaunching` so the Bonjour-expose Combine sink may
    /// begin honoring live config changes with a restart.
    func markLaunchComplete() {
        isLaunchComplete = true
    }

    /// Brings the embedded HTTP server up on the live controller instance if it
    /// is not already running. Used by the App Intents surface to provide a
    /// fast, headless server-up path before issuing a localhost request. No-op
    /// when no controller has been wired (e.g. the app has not finished
    /// launching), in which case callers fall back to retry-with-backoff.
    static func ensureRunning() async {
        guard let controller = ServerControllerHolder.shared.controller else { return }
        if !controller.isRunning {
            await controller.startServer()
        }
    }

    /// Starts the server with current configuration
    func startServer() async {
        guard !isRunning else { return }
        guard configuration.isValidPort else {
            lastErrorMessage = "Invalid port: \(configuration.port). Port must be between 1 and 65535."
            serverHealth = .error(lastErrorMessage!)
            return
        }

        serverHealth = .starting

        do {
            let bindHost = configuration.exposeToNetwork ? "0.0.0.0" : "127.0.0.1"
            self.localNetworkAddress =
                configuration.exposeToNetwork ? self.getLocalIPAddress() : "127.0.0.1"

            print("[Osaurus] Starting NIO server on \(bindHost):\(configuration.port)")

            // Ensure any previous instance is shut down
            try await stopServerIfNeeded()

            let server = OsaurusServer()
            try await server.start(
                .init(host: bindHost, port: configuration.port, trustLoopback: !configuration.exposeToNetwork),
                serverConfiguration: self.configuration
            )
            self.serverActor = server

            // Update state
            isRunning = true
            serverHealth = .running
            lastErrorMessage = nil
            FeatureTelemetry.serverStarted()
            print("[Osaurus] NIO server started successfully on port \(configuration.port)")
            // One-line record of the effective inference policy so any
            // benchmark or bug report can state exactly which knobs were in
            // force without scraping Settings. Values here are the resolved
            // ones (after Settings/UserDefaults precedence), not the raw keys.
            let idleResidency: String
            switch configuration.modelIdleResidencyPolicy {
            case .immediately: idleResidency = "immediately"
            case .afterSeconds(let seconds): idleResidency = "after_seconds(\(seconds))"
            case .never: idleResidency = "never"
            }
            print(
                "[Osaurus] inference policy: maxBatchSize=\(InferenceFeatureFlags.mlxBatchEngineMaxBatchSize) "
                    + "eviction=\(configuration.modelEvictionPolicy.rawValue) "
                    + "idleResidency=\(idleResidency)"
            )

            if configuration.exposeToNetwork {
                BonjourAdvertiser.shared.startAdvertising(port: configuration.port)
            } else {
                BonjourAdvertiser.shared.stopAdvertising()
            }
            RelayTunnelManager.shared.reconnectIfNeeded(port: configuration.port)
        } catch {
            handleServerError(error)
        }
    }

    /// Restarts the server to apply configuration changes
    func restartServer() async {
        isRestarting = true
        serverHealth = .restarting
        defer { isRestarting = false }
        if serverActor != nil || isRunning {
            await stopServer()
        }
        await startServer()
    }

    /// Stops the running server
    func stopServer() async {
        // If nothing to stop, return
        guard serverActor != nil else { return }
        if !isRestarting { serverHealth = .stopping }
        print("[Osaurus] Stopping NIO server...")

        RelayTunnelManager.shared.disconnectAll()
        BonjourAdvertiser.shared.stopAdvertising()
        isRunning = false

        // Stop the actor-backed server if present. The event-loop group is
        // process-shared (`SharedEventLoopGroups.server`), so stop only
        // closes channels — no thread/descriptor churn on restart.
        if let server = serverActor {
            await server.stop(gracefully: true)
            serverActor = nil
        }

        localNetworkAddress = "127.0.0.1"

        if !isRestarting { serverHealth = .stopped }
        print("[Osaurus] Server stopped successfully")
    }

    /// Ensures the server is properly shut down before app termination
    func ensureShutdown() async {
        guard serverActor != nil else { return }

        print("[Osaurus] Ensuring NIO server shutdown before app termination")
        RelayTunnelManager.shared.disconnectAll()
        // Stop mDNS on the quit path too — `stopServer` does this, but
        // `ensureShutdown` is the only teardown the AppDelegate calls, so
        // without this an advertised service could linger past quit.
        BonjourAdvertiser.shared.stopAdvertising()
        isRunning = false
        serverHealth = .stopping

        if let server = serverActor {
            // Termination path: bounded (`gracefully: false`) drain so a
            // lingering SSE child channel can't stall quit. The shared
            // event-loop group is never shut down, so there is no
            // mid-shutdown group to keep rooted (issue #860 no longer
            // applies).
            _ = await server.stop(gracefully: false)
            serverActor = nil
        }

        localNetworkAddress = "127.0.0.1"

        print("[Osaurus] Server shutdown completed")
    }

    // Capture singleton pointer on init attach to UI
    init() {
        ServerControllerHolder.shared.controller = self
        if let saved = ServerConfigurationStore.load() {
            self.configuration = saved
        }
        // Read-only load. The legacy → vmlx migration (which writes to
        // `~/.osaurus/config/`) is intentionally deferred to
        // `bootstrapRuntimeSettings()` so a fresh install stays pristine
        // until the AppDelegate explicitly runs it during launch.
        let existingRuntimeSettings = ServerRuntimeSettingsStore.load()
        if let existing = existingRuntimeSettings {
            self.runtimeSettings = existing
        }
        // `server-runtime.json` is also writable through the admin HTTP
        // endpoint. Observe every successful store save so the published
        // controller value and any open Settings form follow the exact
        // snapshot consumed by runtime code.
        runtimeSettingsCancellable = NotificationCenter.default.publisher(
            for: ServerRuntimeSettingsStore.didSaveNotification
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Read only after reaching the owning actor. Capturing a
                // snapshot before this hop can replay an older notification
                // over a newer explicit Server or Spawn editor save.
                let latest = ServerRuntimeSettingsStore.snapshot()
                if self.runtimeSettings != latest {
                    self.runtimeSettings = latest
                }
                self.synchronizeSpawnBatchLimit(from: latest)
            }
        }
        if let existingRuntimeSettings {
            synchronizeSpawnBatchLimit(from: existingRuntimeSettings)
        }
        // Keep exposeToNetwork in sync with Bonjour-enabled agents.
        // Only turn ON when a Bonjour agent requires it — never force
        // it OFF, so the user's manual "expose to local network" setting
        // is preserved across launches.
        agentsCancellable = AgentManager.shared.$agents
            .sink { agents in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let shouldExpose = agents.contains { $0.bonjourEnabled }
                    // Only act when an agent is forcing exposure ON.
                    // If no agent requires it, leave the user's setting alone.
                    guard shouldExpose, !self.configuration.exposeToNetwork else { return }
                    self.configuration.exposeToNetwork = true
                    self.runtimeSettings.network.host = "0.0.0.0"
                    self.saveConfiguration()
                    ServerRuntimeSettingsStore.save(self.runtimeSettings)
                    // Only restart for a live config change *after* launch has
                    // settled. During launch the initial auto-start already
                    // reads the updated config, so restarting here would be
                    // redundant server churn racing the launch sequence — the
                    // mid-launch restart the hang audit flagged.
                    if self.isRunning && self.isLaunchComplete {
                        await self.restartServer()
                    }
                }
            }
    }

    /// Runs the one-shot legacy → vmlx runtime-settings migration and
    /// publishes the result. Idempotent — on a non-fresh install
    /// `loadOrMigrate()` just returns the on-disk value without
    /// writing.
    ///
    /// Invoked from the AppDelegate during
    /// `applicationDidFinishLaunching`. `init()` skips this because
    /// `ServerController` is constructed as a stored property of the
    /// AppDelegate (i.e. before launch), and the migration's
    /// first-run `save()` would otherwise create
    /// `config/server-runtime.json` in `~/.osaurus/` before the app
    /// is fully up.
    func bootstrapRuntimeSettings() {
        self.runtimeSettings = ServerRuntimeSettingsStore.loadOrMigrate()
        synchronizeSpawnBatchLimit(from: runtimeSettings)
    }

    /// Applies an explicit edit from General -> Main Chat Spawn to the shared
    /// Server concurrency setting. Keeping this an origin-aware call avoids
    /// treating asynchronous persistence notifications as fresh user edits,
    /// which could otherwise replay an older value over a newer Server save.
    func applyMainChatBatchLimit(
        from configuration: SubagentConfiguration
    ) async {
        await applySpawnBatchLimit(
            SpawnBatchConcurrencyContract.configuredLimit(for: configuration)
        )
    }

    /// Origin-aware shared edit used by both the built-in and custom-agent
    /// Spawn editors. Runtime RAM admission and active occupancy may still
    /// execute a smaller wave, but no second configured fan-out value remains.
    func applySpawnBatchLimit(_ value: Int) async {
        let requested = SpawnBatchConcurrencyContract.normalized(value)
        // An explicit Spawn-editor action owns the value even when Automatic
        // currently resolves to the same number. Compare the persisted raw
        // override, not the resolved effective capacity, so nil -> requested
        // materializes the user's edit while an existing identical explicit
        // value remains a true no-op.
        guard runtimeSettings.concurrency.maxConcurrentSequences != requested else {
            synchronizeSpawnBatchLimit(from: runtimeSettings)
            return
        }
        var updated = runtimeSettings
        updated.concurrency.maxConcurrentSequences = requested
        _ = await saveRuntimeSettings(updated)
    }

    private func synchronizeSpawnBatchLimit(
        from settings: VMLXServerRuntimeSettings
    ) {
        let current = SubagentConfigurationStore.snapshot()
        let updated = SpawnBatchConcurrencyContract.applyingServerLimit(
            settings,
            to: current
        )
        guard updated != current else { return }
        SubagentConfigurationStore.mutate { configuration in
            configuration.budgets.maxParallelSpawns =
                updated.budgets.maxParallelSpawns
        }
    }

    /// Checks if the server is responsive
    func checkServerHealth() async -> Bool {
        guard isRunning else { return false }

        do {
            let url = URL(string: "http://127.0.0.1:\(port)/health")!
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            print("[Osaurus] Health check failed: \(error)")
            return false
        }
    }

    /// Saves the current configuration to disk
    func saveConfiguration() {
        ServerConfigurationStore.save(configuration)
    }

    /// Persists the supplied vmlx runtime settings, projects the
    /// network/CORS/generation slice back into the legacy
    /// `ServerConfiguration` JSON, and decides whether the NIO socket
    /// needs to restart.
    ///
    /// Fields that require a NIO restart: port, host (expose toggle),
    /// CORS origins.
    /// Fields that only need a runtime-config invalidate: generation and
    /// concurrency defaults consumed by `RuntimeConfig.snapshot()` on the next
    /// request.
    struct RuntimeSettingsApplyEffects: Equatable, Sendable {
        let unloadedModelCount: Int
        let restartedServer: Bool
        let invalidatedRuntimeConfig: Bool
    }

    @discardableResult
    func saveRuntimeSettings(
        _ requestedSettings: VMLXServerRuntimeSettings
    ) async -> RuntimeSettingsApplyEffects {
        let settings =
            ServerRuntimeSettingsStore.canonicalizedContextAndKVPolicy(
                requestedSettings
            )
        let previousRuntimeSettings = runtimeSettings
        let previousConfig = configuration
        let projected = ServerRuntimeSettingsStore.projectIntoLegacy(
            settings,
            base: previousConfig
        )
        let loadedModelRefreshNeeded = Self.loadedModelRuntimeInputsRequireRefresh(
            previous: previousRuntimeSettings,
            next: settings
        )

        runtimeSettings = settings
        ServerRuntimeSettingsStore.save(settings)
        synchronizeSpawnBatchLimit(from: settings)

        let configChanged = projected != previousConfig
        let restartNeeded =
            previousConfig.port != projected.port
            || previousConfig.exposeToNetwork != projected.exposeToNetwork
            || previousConfig.allowedOrigins != projected.allowedOrigins
        let runtimeConfigChanged =
            Self.runtimeConfigInputsRequireInvalidate(
                previous: previousRuntimeSettings,
                next: settings
            )
            || previousConfig.genTopP != projected.genTopP
        let restartWasRequested = restartNeeded && isRunning

        if configChanged {
            configuration = projected
            saveConfiguration()
        }

        let unloadedModelCount =
            loadedModelRefreshNeeded
            ? await ModelRuntime.shared.cachedModelSummaries().count
            : 0
        if loadedModelRefreshNeeded {
            await ModelRuntime.shared.clearAll()
        }
        if restartWasRequested {
            await restartServer()
        }
        if runtimeConfigChanged {
            await ModelRuntime.shared.invalidateConfig()
        }
        return RuntimeSettingsApplyEffects(
            unloadedModelCount: unloadedModelCount,
            restartedServer: restartWasRequested,
            invalidatedRuntimeConfig: runtimeConfigChanged
        )
    }

    /// Settings that are captured by a loaded `ModelContainer` or the
    /// container-owned `BatchEngine` must force a model refresh. Plain network
    /// and sampling defaults are applied elsewhere on the next request.
    nonisolated static func loadedModelRuntimeInputsRequireRefresh(
        previous: VMLXServerRuntimeSettings,
        next: VMLXServerRuntimeSettings
    ) -> Bool {
        previous.cache != next.cache
            || previous.multimodal != next.multimodal
            || previous.mtp != next.mtp
            // Memory Safety resolves the live KV cap, prefix-memory budget,
            // allocator cap, and companion-cache entry limit at model load.
            // Persisting a new profile while retaining the old container makes
            // the settings panel lie until a manual reload.
            || previous.memorySafety != next.memorySafety
    }

    /// Settings captured by `RuntimeConfig.snapshot()` but not by a loaded
    /// model container must be re-read on the next request after saving.
    nonisolated static func runtimeConfigInputsRequireInvalidate(
        previous: VMLXServerRuntimeSettings,
        next: VMLXServerRuntimeSettings
    ) -> Bool {
        previous.generation != next.generation
            || previous.concurrency != next.concurrency
    }

    // MARK: - Private Helpers

    /// Handles server startup errors
    private func handleServerError(_ error: Error) {
        print("[Osaurus] Failed to start server: \(error)")
        isRunning = false
        let desc = error.localizedDescription.lowercased()
        if desc.contains("address already in use") || desc.contains("eaddrinuse") {
            lastErrorMessage =
                "Port \(configuration.port) is already in use. Choose a different port in Settings."
        } else if desc.contains("permission denied") || desc.contains("eacces") {
            lastErrorMessage = "Permission denied for port \(configuration.port). Use a port above 1024."
        } else {
            lastErrorMessage = error.localizedDescription
        }
        serverHealth = .error(lastErrorMessage ?? error.localizedDescription)
    }

    private func stopServerIfNeeded() async throws {
        if serverActor != nil {
            await stopServer()
        }
    }

    private func getLocalIPAddress() -> String {
        var address: String = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return address }
        guard let firstAddr = ifaddr else { return address }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee

            // Check for running IPv4 interface, and skip loopback
            if (flags & (IFF_UP | IFF_RUNNING | IFF_LOOPBACK)) == (IFF_UP | IFF_RUNNING) {
                if addr.sa_family == AF_INET {
                    // Found an active IPv4 address
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(
                        ptr.pointee.ifa_addr,
                        socklen_t(addr.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        socklen_t(0),
                        NI_NUMERICHOST
                    ) == 0 {
                        // Trim at NUL terminator before decoding to avoid deprecated cString initializer.
                        let nulTrimmed = hostname.prefix { $0 != 0 }
                        let ip = String(decoding: nulTrimmed.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        let name = String(cString: ptr.pointee.ifa_name)
                        if name.starts(with: "en") {  // en0, en1, etc. are common for Wi-Fi/Ethernet on macOS
                            address = ip
                            break
                        }
                    }
                }

            }
        }

        freeifaddrs(ifaddr)
        return address
    }
}
