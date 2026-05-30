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

    /// Convenience property for accessing port
    var port: Int {
        get { configuration.port }
        set { configuration.port = newValue }
    }

    // MARK: - Private Properties

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private var serverActor: OsaurusServer?
    private var agentsCancellable: AnyCancellable?

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
            print("[Osaurus] NIO server started successfully on port \(configuration.port)")

            if configuration.exposeToNetwork {
                BonjourAdvertiser.shared.startAdvertising(port: configuration.port)
            } else {
                BonjourAdvertiser.shared.stopAdvertising()
            }
            RelayTunnelManager.shared.reconnectIfNeeded(port: configuration.port)
        } catch {
            handleServerError(error)
            await cleanupRuntime()
        }
    }

    /// Restarts the server to apply configuration changes
    func restartServer() async {
        isRestarting = true
        serverHealth = .restarting
        defer { isRestarting = false }
        if serverChannel != nil || eventLoopGroup != nil || isRunning {
            await stopServer()
        }
        await startServer()
    }

    /// Stops the running server
    func stopServer() async {
        // If nothing to stop, return
        guard serverActor != nil || serverChannel != nil || eventLoopGroup != nil else { return }
        if !isRestarting { serverHealth = .stopping }
        print("[Osaurus] Stopping NIO server...")

        RelayTunnelManager.shared.disconnectAll()
        BonjourAdvertiser.shared.stopAdvertising()
        isRunning = false

        // Stop the actor-backed server if present
        if let server = serverActor {
            await server.stop(gracefully: true)
            serverActor = nil
        }

        localNetworkAddress = "127.0.0.1"
        await cleanupRuntime()

        if !isRestarting { serverHealth = .stopped }
        print("[Osaurus] Server stopped successfully")
    }

    /// Ensures the server is properly shut down before app termination
    func ensureShutdown() async {
        guard serverActor != nil || serverChannel != nil || eventLoopGroup != nil else { return }

        print("[Osaurus] Ensuring NIO server shutdown before app termination")
        RelayTunnelManager.shared.disconnectAll()
        isRunning = false
        serverHealth = .stopping

        if let server = serverActor {
            await server.stop(gracefully: true)
            serverActor = nil
        }

        localNetworkAddress = "127.0.0.1"
        await cleanupRuntime()

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
        // `bootstrapRuntimeSettings()` so a fresh install stays
        // pristine until after the storage migrator's gate runs.
        if let existing = ServerRuntimeSettingsStore.load() {
            self.runtimeSettings = existing
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
                    if self.isRunning {
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
    /// Must be invoked from the AppDelegate immediately after
    /// `StorageMigrationCoordinator.blockingAwaitReady()` returns.
    /// `init()` skips this because `ServerController` is constructed
    /// as a stored property of the AppDelegate (i.e. before
    /// `applicationDidFinishLaunching`), and the migration's first-run
    /// `save()` would otherwise create `config/server-runtime.json`
    /// in `~/.osaurus/` *before* the storage migrator's
    /// `isPristineInstall()` check, flipping a true fresh install
    /// out of the pristine fast path and painting the "Securing your
    /// data" overlay over onboarding.
    func bootstrapRuntimeSettings() {
        self.runtimeSettings = ServerRuntimeSettingsStore.loadOrMigrate()
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
    func saveRuntimeSettings(_ settings: VMLXServerRuntimeSettings) async {
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

        if configChanged {
            configuration = projected
            saveConfiguration()
        }

        if loadedModelRefreshNeeded {
            await ModelRuntime.shared.clearAll()
        }
        if restartNeeded, isRunning {
            await restartServer()
        }
        if runtimeConfigChanged {
            await ModelRuntime.shared.invalidateConfig()
        }
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

    /// Sets up channel closure handler
    private func setupChannelClosureHandler(_ channel: Channel) {
        channel.closeFuture.whenComplete { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isRunning = false
                if !self.isRestarting { self.serverHealth = .stopped }
                self.serverChannel = nil
            }
        }
    }

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
        if serverActor != nil || serverChannel != nil || eventLoopGroup != nil {
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

    private func cleanupRuntime() async {
        // Shutdown the event loop group gracefully
        if let group = eventLoopGroup {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                group.shutdownGracefully { error in
                    if let error {
                        print("[Osaurus] Error shutting down EventLoopGroup: \(error)")
                    }
                    continuation.resume()
                }
            }
            eventLoopGroup = nil
        }
    }
}
