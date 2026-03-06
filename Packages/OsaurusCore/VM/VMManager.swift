//
//  VMManager.swift
//  osaurus
//
//  Manages per-agent Linux VM lifecycles using Virtualization.framework.
//  VMs use VZEFIBootLoader with Alpine ISO on first boot.
//  Vsock connects best-effort with retry (shim may not be running yet).
//

import Foundation
import Virtualization

public enum VMError: Error, LocalizedError {
    case vmNotFound(UUID)
    case alreadyRunning(UUID)
    case bootFailed(String)
    case noVMConfig(UUID)
    case vsockConnectionFailed
    case isoNotAvailable
    case busy(UUID)

    public var errorDescription: String? {
        switch self {
        case .vmNotFound(let id): return "No VM found for agent \(id)"
        case .alreadyRunning(let id): return "VM already running for agent \(id)"
        case .bootFailed(let msg): return "VM boot failed: \(msg)"
        case .noVMConfig(let id): return "Agent \(id) has no VM configuration"
        case .vsockConnectionFailed: return "Failed to connect to VM via vsock"
        case .isoNotAvailable: return "Alpine ISO not available. Download the VM runtime first."
        case .busy(let id): return "VM for agent \(id) is already booting or shutting down"
        }
    }
}

/// Tracks a running VM instance and its associated resources.
final class VMInstance: @unchecked Sendable {
    let agentId: UUID
    var vm: VZVirtualMachine
    var consolePipes: (input: Pipe, output: Pipe)?
    var vsockConnection: VsockConnection?
    var hostAPIServer: VsockHostAPIServer?
    var vsockRetryTask: Task<Void, Never>?

    init(agentId: UUID, vm: VZVirtualMachine, consolePipes: (input: Pipe, output: Pipe)? = nil) {
        self.agentId = agentId
        self.vm = vm
        self.consolePipes = consolePipes
    }
}

@MainActor
public final class VMManager: ObservableObject {
    public static let shared = VMManager()

    @Published private(set) var runningVMs: [UUID: VMInstance] = [:]

    /// Prevents concurrent boot/shutdown for the same agent.
    private var busyAgents: Set<UUID> = []

    private init() {}

    // MARK: - Lifecycle

    /// Boot the VM for the given agent. Creates disk image if needed.
    /// On first boot, runs automated provisioning (install Alpine, configure system, deploy shim).
    public func boot(agentId: UUID, vmConfig: VMConfig) async throws {
        guard !busyAgents.contains(agentId) else {
            throw VMError.busy(agentId)
        }
        guard runningVMs[agentId] == nil else { return }

        busyAgents.insert(agentId)
        defer { busyAgents.remove(agentId) }

        guard VMRuntimeDownloader.shared.isRuntimeAvailable else {
            throw VMError.isoNotAvailable
        }

        try DiskImageManager.shared.createAgentDisk(for: agentId)
        deployShimToInput(agentId: agentId)

        let needsInstall = DiskImageManager.shared.needsInstall(for: agentId)

        if needsInstall {
            try await provisionNewVM(agentId: agentId, vmConfig: vmConfig)
        } else {
            try await startVM(agentId: agentId, vmConfig: vmConfig, needsInstall: false)
        }

        if let instance = runningVMs[agentId] {
            startVsockRetry(for: instance)
        }
    }

    /// Two-boot provisioning sequence for a fresh VM.
    private func provisionNewVM(agentId: UUID, vmConfig: VMConfig) async throws {
        VMBootLog.shared.setPhase(agentId: agentId, .booting)
        VMBootLog.shared.append(agentId: agentId, phase: .booting, message: "Extracting kernel from ISO...")

        // Extract kernel/initrd off MainActor so hdiutil doesn't block the UI
        let (kernelURL, initrdURL) = try await VMConfigurationBuilder.extractKernelFromISO(for: agentId)
        VMBootLog.shared.append(agentId: agentId, phase: .booting, message: "Kernel extracted, building VM config...")

        // Phase 1: Boot with ISO kernel (VZLinuxBootLoader + console=hvc0)
        let (config1, pipes1) = try VMConfigurationBuilder.build(
            agentId: agentId, vmConfig: vmConfig, needsInstall: true,
            kernelURL: kernelURL, initrdURL: initrdURL
        )
        let vm1 = VZVirtualMachine(configuration: config1)
        let instance1 = VMInstance(agentId: agentId, vm: vm1, consolePipes: pipes1)
        runningVMs[agentId] = instance1

        try await startVMProcess(vm1)
        NSLog("[VMManager] Phase 1: VM booted from ISO for agent %@", agentId.uuidString)

        let provisioner1 = VMProvisioner(inputPipe: pipes1.input, outputPipe: pipes1.output, agentId: agentId)
        do {
            try await provisioner1.installOS()
        } catch {
            VMBootLog.shared.setPhase(agentId: agentId, .failed)
            VMBootLog.shared.append(agentId: agentId, phase: .failed, message: error.localizedDescription)
            VMBootLog.shared.persist(agentId: agentId)
            runningVMs.removeValue(forKey: agentId)
            throw error
        }

        // Wait for the VM to stop after poweroff
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        if vm1.state != .stopped {
            try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                vm1.stop { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        }
        runningVMs.removeValue(forKey: agentId)
        NSLog("[VMManager] Phase 1 complete: VM stopped for agent %@", agentId.uuidString)

        VMBootLog.shared.setPhase(agentId: agentId, .rebooting)

        // Phase 2: Boot from disk (no ISO), configure system
        let (config2, pipes2) = try VMConfigurationBuilder.build(
            agentId: agentId, vmConfig: vmConfig, needsInstall: false
        )
        let vm2 = VZVirtualMachine(configuration: config2)
        let instance2 = VMInstance(agentId: agentId, vm: vm2, consolePipes: pipes2)
        runningVMs[agentId] = instance2

        try await startVMProcess(vm2)
        NSLog("[VMManager] Phase 2: VM booted from disk for agent %@", agentId.uuidString)

        let provisioner2 = VMProvisioner(inputPipe: pipes2.input, outputPipe: pipes2.output, agentId: agentId)
        do {
            try await provisioner2.configureSystem()
        } catch {
            VMBootLog.shared.setPhase(agentId: agentId, .failed)
            VMBootLog.shared.append(agentId: agentId, phase: .failed, message: error.localizedDescription)
            VMBootLog.shared.persist(agentId: agentId)
            throw error
        }

        DiskImageManager.shared.markProvisioned(for: agentId)
        VMBootLog.shared.persist(agentId: agentId)
        NSLog("[VMManager] Provisioning complete for agent %@", agentId.uuidString)
    }

    /// Boot a VM without provisioning.
    private func startVM(agentId: UUID, vmConfig: VMConfig, needsInstall: Bool) async throws {
        let (config, pipes) = try VMConfigurationBuilder.build(
            agentId: agentId, vmConfig: vmConfig, needsInstall: needsInstall
        )
        let vm = VZVirtualMachine(configuration: config)
        let instance = VMInstance(agentId: agentId, vm: vm, consolePipes: pipes)
        runningVMs[agentId] = instance

        try await startVMProcess(vm)
        NSLog("[VMManager] VM started for agent %@", agentId.uuidString)
    }

    /// Start the VZ VM process and wait for it to be running.
    private func startVMProcess(_ vm: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vm.start { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: VMError.bootFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Copy the Python shim to the agent's read-only input directory before boot.
    private func deployShimToInput(agentId: UUID) {
        let inputDir = OsaurusPaths.agentInput(agentId)
        OsaurusPaths.ensureExistsSilent(inputDir)
        let destURL = inputDir.appendingPathComponent("osaurus-host.py")
        guard !FileManager.default.fileExists(atPath: destURL.path) else { return }

        // The Python shim is co-located in the VM source directory
        let shimName = "osaurus_host"
        if let sourceURL = Bundle.main.url(forResource: shimName, withExtension: "py") {
            try? FileManager.default.copyItem(at: sourceURL, to: destURL)
        } else {
            // Fallback: look relative to the OsaurusCore package source
            let fallbackURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("osaurus_host.py")
            if FileManager.default.fileExists(atPath: fallbackURL.path) {
                try? FileManager.default.copyItem(at: fallbackURL, to: destURL)
            }
        }
    }

    /// Shut down the VM for the given agent.
    public func shutdown(agentId: UUID) async throws {
        guard !busyAgents.contains(agentId) else {
            throw VMError.busy(agentId)
        }
        guard let instance = runningVMs[agentId] else { return }

        busyAgents.insert(agentId)
        defer { busyAgents.remove(agentId) }

        instance.vsockRetryTask?.cancel()
        instance.vsockRetryTask = nil

        await MCPBridge.shared.stopAll(for: agentId)
        await instance.hostAPIServer?.stop()
        instance.vsockConnection?.disconnect()

        if instance.vm.canRequestStop {
            try instance.vm.requestStop()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            instance.vm.stop { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        runningVMs.removeValue(forKey: agentId)
        NSLog("[VMManager] VM stopped for agent %@", agentId.uuidString)
    }

    /// Whether a VM is running for the given agent.
    public func isRunning(_ agentId: UUID) -> Bool {
        runningVMs[agentId] != nil
    }

    /// Ensure a VM is running, booting if needed.
    public func ensureRunning(agentId: UUID) async throws {
        if isRunning(agentId) { return }

        let agent = AgentManager.shared.agents.first(where: { $0.id == agentId })
        let vmConfig = agent?.vmConfig ?? VMConfig()
        try await boot(agentId: agentId, vmConfig: vmConfig)
    }

    /// Get the vsock connection for a running VM.
    public func vsockConnection(for agentId: UUID) -> VsockConnection? {
        runningVMs[agentId]?.vsockConnection
    }

    /// Shut down all running VMs.
    public func shutdownAll() async {
        for agentId in runningVMs.keys {
            try? await shutdown(agentId: agentId)
        }
    }

    // MARK: - Vsock (best-effort with retry)

    /// Try to connect vsock immediately. If it fails, start a background retry loop.
    private func startVsockRetry(for instance: VMInstance) {
        let agentId = instance.agentId

        instance.vsockRetryTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self, self.runningVMs[agentId] != nil else { break }

                if let inst = self.runningVMs[agentId], await self.tryVsockConnect(for: inst) {
                    NSLog("[VMManager] Vsock connected on attempt #%d for agent %@", attempt + 1, agentId.uuidString)
                    break
                }

                attempt += 1
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
            }
        }
    }

    /// Attempt a single vsock connect + Host API server setup. Returns true on success.
    private func tryVsockConnect(for instance: VMInstance) async -> Bool {
        guard let socketDevice = instance.vm.socketDevices.first as? VZVirtioSocketDevice else {
            return false
        }

        let connection = VsockConnection(socketDevice: socketDevice, port: vsockPort)

        let fd: Int32? = await withCheckedContinuation { continuation in
            socketDevice.connect(toPort: vsockPort) { result in
                switch result {
                case .success(let conn):
                    continuation.resume(returning: conn.fileDescriptor)
                case .failure:
                    continuation.resume(returning: nil)
                }
            }
        }

        guard let fd else { return false }
        connection.setFileDescriptor(fd)
        instance.vsockConnection = connection

        let agentId = instance.agentId
        nonisolated(unsafe) let device = socketDevice
        let server = VsockHostAPIServer(agentId: agentId, socketDevice: device)
        await server.start()
        instance.hostAPIServer = server

        return true
    }
}
