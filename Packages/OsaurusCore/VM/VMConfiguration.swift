//
//  VMConfiguration.swift
//  osaurus
//
//  Builds VZVirtualMachineConfiguration for agent VMs.
//  First boot uses VZLinuxBootLoader (kernel extracted from ISO) so we can
//  set console=hvc0 for serial access. Subsequent boots use VZEFIBootLoader.
//

import Foundation
import Virtualization

enum VMConfigurationError: Error, LocalizedError {
    case diskImageNotFound(UUID)
    case isoNotFound
    case nvramCreationFailed(String)
    case configurationInvalid(String)
    case kernelExtractionFailed(String)

    var errorDescription: String? {
        switch self {
        case .diskImageNotFound(let id): return "Disk image not found for agent \(id)"
        case .isoNotFound: return "Alpine ISO not found. Download the VM runtime first."
        case .nvramCreationFailed(let msg): return "Failed to create EFI NVRAM: \(msg)"
        case .configurationInvalid(let msg): return "VM configuration invalid: \(msg)"
        case .kernelExtractionFailed(let msg): return "Failed to extract kernel from ISO: \(msg)"
        }
    }
}

/// Vsock port for host-to-VM communication (VsockConnection).
let vsockHostToVM: UInt32 = 5000
/// Vsock port for VM-to-host communication (VsockHostAPIServer).
let vsockVMToHost: UInt32 = 5001

/// Legacy alias used by existing code referencing the host-to-VM port.
let vsockPort: UInt32 = vsockHostToVM

struct VMConfigurationBuilder {

    /// Build a VZVirtualMachineConfiguration for an agent.
    ///
    /// When `needsInstall` is true, uses VZLinuxBootLoader with the kernel extracted
    /// from the Alpine ISO so we can set `console=hvc0` for serial console access.
    /// The ISO is attached as a USB device for setup-alpine to install from.
    /// Call `extractKernelFromISO(for:)` before this when `needsInstall` is true.
    ///
    /// When `needsInstall` is false, uses VZEFIBootLoader to boot the installed system.
    static func build(
        agentId: UUID,
        vmConfig: VMConfig,
        needsInstall: Bool,
        kernelURL: URL? = nil,
        initrdURL: URL? = nil
    ) throws -> (config: VZVirtualMachineConfiguration, consolePipes: (input: Pipe, output: Pipe)) {
        let config = VZVirtualMachineConfiguration()

        config.cpuCount = max(1, min(vmConfig.cpus, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        config.memorySize = max(
            VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            min(vmConfig.memoryBytes, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        )

        // Platform
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = try loadOrCreateMachineIdentifier(for: agentId)
        config.platform = platform

        // Boot Loader
        if needsInstall, let kernelURL, let initrdURL {
            let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
            bootLoader.initialRamdiskURL = initrdURL
            bootLoader.commandLine = "modules=loop,squashfs,sd-mod,usb-storage console=hvc0"
            config.bootLoader = bootLoader
        } else {
            let bootLoader = VZEFIBootLoader()
            bootLoader.variableStore = try loadOrCreateNVRAM(for: agentId)
            config.bootLoader = bootLoader
        }

        // Serial console
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: inputPipe.fileHandleForReading,
            fileHandleForWriting: outputPipe.fileHandleForWriting
        )
        config.serialPorts = [serialPort]

        // Storage devices
        var storageDevices: [VZStorageDeviceConfiguration] = []

        // Main disk
        let diskPath = OsaurusPaths.agentDiskImage(agentId)
        guard FileManager.default.fileExists(atPath: diskPath.path) else {
            throw VMConfigurationError.diskImageNotFound(agentId)
        }
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskPath, readOnly: false)
        storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: diskAttachment))

        // Alpine ISO as USB on first boot (setup-alpine reads packages from it)
        if needsInstall {
            let isoPath = OsaurusPaths.alpineISO()
            guard FileManager.default.fileExists(atPath: isoPath.path) else {
                throw VMConfigurationError.isoNotFound
            }
            let isoAttachment = try VZDiskImageStorageDeviceAttachment(url: isoPath, readOnly: true)
            storageDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: isoAttachment))
        }

        config.storageDevices = storageDevices

        // Shared directories
        var shares: [VZVirtioFileSystemDeviceConfiguration] = []

        let workspaceShare = VZVirtioFileSystemDeviceConfiguration(tag: "workspace")
        workspaceShare.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: OsaurusPaths.agentWorkspace(agentId), readOnly: false)
        )
        shares.append(workspaceShare)

        let inputShare = VZVirtioFileSystemDeviceConfiguration(tag: "input")
        inputShare.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: OsaurusPaths.agentInput(agentId), readOnly: true)
        )
        shares.append(inputShare)

        let outputShare = VZVirtioFileSystemDeviceConfiguration(tag: "output")
        outputShare.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: OsaurusPaths.agentOutput(agentId), readOnly: false)
        )
        shares.append(outputShare)

        config.directorySharingDevices = shares

        // Vsock
        let vsockDevice = VZVirtioSocketDeviceConfiguration()
        config.socketDevices = [vsockDevice]

        // Network
        if vmConfig.network == "outbound" {
            let networkDevice = VZVirtioNetworkDeviceConfiguration()
            networkDevice.attachment = VZNATNetworkDeviceAttachment()
            config.networkDevices = [networkDevice]
        }

        // Entropy
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

        try config.validate()
        return (config, (inputPipe, outputPipe))
    }

    // MARK: - Kernel Extraction

    /// Extract vmlinuz-virt and initramfs-virt from the Alpine ISO using hdiutil.
    /// Caches them in the agent's VM directory so we only mount the ISO once.
    /// This is nonisolated so it can run off-MainActor without blocking the UI.
    static func extractKernelFromISO(for agentId: UUID) async throws -> (kernel: URL, initrd: URL) {
        let vmDir = OsaurusPaths.agentVM(agentId)
        let kernelDest = vmDir.appendingPathComponent("vmlinuz-virt")
        let initrdDest = vmDir.appendingPathComponent("initramfs-virt")

        if FileManager.default.fileExists(atPath: kernelDest.path),
           FileManager.default.fileExists(atPath: initrdDest.path) {
            return (kernelDest, initrdDest)
        }

        let isoPath = OsaurusPaths.alpineISO()
        guard FileManager.default.fileExists(atPath: isoPath.path) else {
            throw VMConfigurationError.isoNotFound
        }

        OsaurusPaths.ensureExistsSilent(vmDir)

        NSLog("[VMConfig] Mounting ISO to extract kernel for agent %@", agentId.uuidString)

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let mountPoint = FileManager.default.temporaryDirectory
                    .appendingPathComponent("osaurus-iso-\(UUID().uuidString)")
                OsaurusPaths.ensureExistsSilent(mountPoint)

                do {
                    let attach = Process()
                    attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    attach.arguments = ["attach", isoPath.path, "-mountpoint", mountPoint.path,
                                        "-nobrowse", "-readonly", "-noverify", "-quiet"]
                    let attachPipe = Pipe()
                    attach.standardError = attachPipe
                    try attach.run()
                    attach.waitUntilExit()

                    defer {
                        let detach = Process()
                        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                        detach.arguments = ["detach", mountPoint.path, "-quiet"]
                        try? detach.run()
                        detach.waitUntilExit()
                        try? FileManager.default.removeItem(at: mountPoint)
                    }

                    guard attach.terminationStatus == 0 else {
                        let stderr = String(data: attachPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        throw VMConfigurationError.kernelExtractionFailed("hdiutil attach failed: \(stderr)")
                    }

                    let kernelSource = mountPoint.appendingPathComponent("boot/vmlinuz-virt")
                    let initrdSource = mountPoint.appendingPathComponent("boot/initramfs-virt")

                    guard FileManager.default.fileExists(atPath: kernelSource.path) else {
                        throw VMConfigurationError.kernelExtractionFailed("vmlinuz-virt not found in ISO")
                    }
                    guard FileManager.default.fileExists(atPath: initrdSource.path) else {
                        throw VMConfigurationError.kernelExtractionFailed("initramfs-virt not found in ISO")
                    }

                    try FileManager.default.copyItem(at: kernelSource, to: kernelDest)
                    try FileManager.default.copyItem(at: initrdSource, to: initrdDest)

                    NSLog("[VMConfig] Extracted kernel and initrd from ISO for agent %@", agentId.uuidString)
                    continuation.resume(returning: (kernelDest, initrdDest))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - NVRAM

    private static func loadOrCreateNVRAM(for agentId: UUID) throws -> VZEFIVariableStore {
        let nvramPath = OsaurusPaths.agentNVRAM(agentId)

        if FileManager.default.fileExists(atPath: nvramPath.path) {
            return VZEFIVariableStore(url: nvramPath)
        }

        OsaurusPaths.ensureExistsSilent(nvramPath.deletingLastPathComponent())
        do {
            return try VZEFIVariableStore(creatingVariableStoreAt: nvramPath)
        } catch {
            throw VMConfigurationError.nvramCreationFailed(error.localizedDescription)
        }
    }

    // MARK: - Machine Identifier

    private static func loadOrCreateMachineIdentifier(for agentId: UUID) throws -> VZGenericMachineIdentifier {
        let idPath = OsaurusPaths.agentMachineIdentifier(agentId)

        if let data = try? Data(contentsOf: idPath),
           let identifier = VZGenericMachineIdentifier(dataRepresentation: data) {
            return identifier
        }

        let identifier = VZGenericMachineIdentifier()
        OsaurusPaths.ensureExistsSilent(idPath.deletingLastPathComponent())
        try identifier.dataRepresentation.write(to: idPath)
        return identifier
    }
}
