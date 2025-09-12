//
//  ServerController.swift
//  osaurus
//
//  Created by Terence on 8/17/25.
//

import Darwin
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import Network

/// Main controller responsible for managing the server lifecycle
@MainActor
final class ServerController: ObservableObject {
  // MARK: - Published Properties

  @Published var isRunning: Bool = false
  @Published var lastErrorMessage: String?
  @Published var serverHealth: ServerHealth = .stopped
  @Published var localNetworkAddress: String = "127.0.0.1"
  @Published var configuration: ServerConfiguration = .default

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

  // Singleton holder to allow async access to the current controller instance when injected as EnvironmentObject
  private struct ServerControllerHolder {
    static var shared = ServerControllerHolder()
    weak var controller: ServerController?
    private init() {}
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

    // Preflight: if anything is already listening on this port, abort early with a friendly message
    var hostsToProbe = ["127.0.0.1", "::1"]
    if configuration.exposeToNetwork {
      let lanIP = self.getLocalIPAddress()
      if !hostsToProbe.contains(lanIP) { hostsToProbe.append(lanIP) }
    }
    if await isAnyListenerActive(on: hostsToProbe, port: configuration.port, timeout: 0.25) {
      lastErrorMessage =
        "Port \(configuration.port) is already in use. Choose a different port in Settings."
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

      // Create event loop group (allow env-based override to reduce contention)
      let env = ProcessInfo.processInfo.environment
      let nioThreads = Int(env["OSU_NIO_THREADS"] ?? "") ?? configuration.numberOfThreads
      let group = MultiThreadedEventLoopGroup(numberOfThreads: nioThreads)
      self.eventLoopGroup = group

      // Bootstrap server using a nonisolated creator to avoid MainActor hops
      let currentConfig = self.configuration
      let bootstrap = ServerController.createServerBootstrap(
        group: group, configuration: currentConfig)

      // Bind to configured host and port (async-safe)
      let channel = try await bootstrap.bind(host: bindHost, port: configuration.port).get()
      self.serverChannel = channel

      // Update state
      isRunning = true
      serverHealth = .running
      lastErrorMessage = nil
      print("[Osaurus] NIO server started successfully on port \(configuration.port)")

      // Handle channel closure
      setupChannelClosureHandler(channel)

      // Best-effort warm-up to reduce TTFT on first request.
      // Environment variables:
      //   OSU_WARMUP_MODEL   - optional model name to warm up
      //   OSU_WARMUP_TOKENS  - number of tokens to generate during warm-up (default 16)
      //   OSU_WARMUP_PREFILL - approximate number of characters for prefill warmup (default 16384)
      Task {
        let env = ProcessInfo.processInfo.environment
        let envModel = env["OSU_WARMUP_MODEL"]
        // More aggressive defaults compile prefill/decoding paths better
        let warmTokens = Int(env["OSU_WARMUP_TOKENS"] ?? "") ?? 16
        let prefillChars = Int(env["OSU_WARMUP_PREFILL"] ?? "") ?? 16384
        await MLXService.shared.warmUp(
          modelName: envModel, prefillChars: max(0, prefillChars), maxTokens: max(1, warmTokens))
      }
    } catch {
      handleServerError(error)
      await cleanupRuntime()
    }
  }

  /// Stops the running server
  func stopServer() async {
    // If nothing to stop, return
    guard serverChannel != nil || eventLoopGroup != nil else { return }

    serverHealth = .stopping
    print("[Osaurus] Stopping NIO server...")

    isRunning = false

    // Close the server channel if present
    if let channel = serverChannel {
      do { try await channel.close().get() } catch {
        print("[Osaurus] Error closing channel: \(error)")
      }
      serverChannel = nil
    }

    localNetworkAddress = "127.0.0.1"
    await cleanupRuntime()

    serverHealth = .stopped
    print("[Osaurus] Server stopped successfully")
  }

  /// Ensures the server is properly shut down before app termination
  func ensureShutdown() async {
    guard serverChannel != nil || eventLoopGroup != nil else { return }

    print("[Osaurus] Ensuring NIO server shutdown before app termination")
    isRunning = false
    serverHealth = .stopping

    if let channel = serverChannel {
      do { try await channel.close().get() } catch {
        print("[Osaurus] Error closing channel: \(error)")
      }
      serverChannel = nil
    }

    localNetworkAddress = "127.0.0.1"
    await cleanupRuntime()

    print("[Osaurus] Server shutdown completed")
  }

  // Capture singleton pointer on init attach to UI
  init() {
    ServerControllerHolder.shared.controller = self
    // Load persisted configuration if available
    if let saved = ServerConfigurationStore.load() {
      self.configuration = saved
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

  // MARK: - Private Helpers

  /// Creates configured server bootstrap outside of MainActor to ensure pipeline ops run on the channel's EventLoop
  nonisolated static func createServerBootstrap(
    group: EventLoopGroup, configuration: ServerConfiguration
  ) -> ServerBootstrap {
    let env = ProcessInfo.processInfo.environment
    let maxMessagesPerReadEnv = Int(env["OSU_NIO_MAX_MESSAGES_PER_READ"] ?? "") ?? 8
    let maxMessagesPerRead: ChannelOptions.Types.MaxMessagesPerReadOption.Value = numericCast(
      maxMessagesPerReadEnv)
    return ServerBootstrap(group: group)
      // Server options
      .serverChannelOption(ChannelOptions.backlog, value: configuration.backlog)
      .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      // Child channels (accepted connections)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline(
          withPipeliningAssistance: false, withErrorHandling: false
        ).flatMap {
          channel.pipeline.addHandler(HTTPHandler())
        }
      }
      .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
      .childChannelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
      .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .childChannelOption(ChannelOptions.maxMessagesPerRead, value: maxMessagesPerRead)
      .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())
  }

  /// Sets up channel closure handler
  private func setupChannelClosureHandler(_ channel: Channel) {
    channel.closeFuture.whenComplete { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.isRunning = false
        self.serverHealth = .stopped
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

  // MARK: - Port Probe (Network-based, concurrency-safe)

  private func isAnyListenerActive(on hosts: [String], port: Int, timeout: TimeInterval) async
    -> Bool
  {
    for host in hosts {
      if await isListenerActive(host: host, port: port, timeout: timeout) {
        return true
      }
    }
    return false
  }

  private func isListenerActive(host: String, port: Int, timeout: TimeInterval) async -> Bool {
    guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
    let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)

    let stateStream = AsyncStream<NWConnection.State> { continuation in
      connection.stateUpdateHandler = { state in
        continuation.yield(state)
        switch state {
        case .ready, .failed(_), .cancelled:
          continuation.finish()
        default:
          break
        }
      }
      connection.start(queue: DispatchQueue.global(qos: .utility))
    }

    return await withTaskGroup(of: Bool.self) { group in
      // Task 1: Wait for connection state
      group.addTask {
        for await state in stateStream {
          switch state {
          case .ready:
            connection.cancel()
            return true
          case .failed(_), .cancelled:
            return false
          default:
            break
          }
        }
        return false
      }

      // Task 2: Timeout
      group.addTask {
        let ns = UInt64(max(0, timeout) * 1_000_000_000)
        // Best-effort timeout; ignore cancellation/throwing semantics
        try? await Task.sleep(nanoseconds: ns)
        connection.cancel()
        return false
      }

      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
  }

  private func stopServerIfNeeded() async throws {
    if serverChannel != nil || eventLoopGroup != nil {
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
            ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil,
            socklen_t(0), NI_NUMERICHOST) == 0
          {
            let ip = String(cString: hostname)
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
