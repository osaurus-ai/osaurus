//
//  DiskImageManager.swift
//  osaurus
//
//  Manages per-agent disk images using Apple's recommended open+ftruncate
//  pattern. The disk starts blank; the Alpine ISO installer populates it
//  during the VM's first EFI boot.
//

import Foundation

public enum DiskImageError: Error, LocalizedError {
    case diskCreationFailed(String)
    case isoNotFound

    public var errorDescription: String? {
        switch self {
        case .diskCreationFailed(let msg): return "Failed to create disk image: \(msg)"
        case .isoNotFound: return "Alpine ISO not found. Download the VM runtime first."
        }
    }
}

public final class DiskImageManager: Sendable {
    /// Default disk size: 64 GB (sparse — actual file is small until written to).
    public static let defaultDiskSize: UInt64 = 64 * 1024 * 1024 * 1024
    public static let shared = DiskImageManager()

    private init() {}

    /// Whether the Alpine ISO has been downloaded.
    public var isoExists: Bool {
        FileManager.default.fileExists(atPath: OsaurusPaths.alpineISO().path)
    }

    /// Whether a disk image exists for the given agent.
    public func agentDiskExists(for agentId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: OsaurusPaths.agentDiskImage(agentId).path)
    }

    /// Whether this agent needs a first-boot install.
    /// True only when there's no NVRAM (never booted) and the provisioned sentinel is absent.
    public func needsInstall(for agentId: UUID) -> Bool {
        !FileManager.default.fileExists(atPath: OsaurusPaths.agentNVRAM(agentId).path)
            && !isProvisioned(for: agentId)
    }

    /// Whether the provisioned sentinel exists for this agent.
    public func isProvisioned(for agentId: UUID) -> Bool {
        FileManager.default.fileExists(atPath: OsaurusPaths.agentProvisionedMarker(agentId).path)
    }

    /// Write the provisioned sentinel after successful provisioning.
    public func markProvisioned(for agentId: UUID) {
        let url = OsaurusPaths.agentProvisionedMarker(agentId)
        OsaurusPaths.ensureExistsSilent(url.deletingLastPathComponent())
        FileManager.default.createFile(atPath: url.path, contents: Data())
    }

    /// Create a blank disk image for the agent using open+ftruncate (Apple's pattern).
    /// Also ensures workspace/input/output directories exist.
    public func createAgentDisk(for agentId: UUID, size: UInt64 = DiskImageManager.defaultDiskSize) throws {
        let diskPath = OsaurusPaths.agentDiskImage(agentId)
        guard !FileManager.default.fileExists(atPath: diskPath.path) else { return }

        guard isoExists else { throw DiskImageError.isoNotFound }

        let vmDir = OsaurusPaths.agentVM(agentId)
        OsaurusPaths.ensureExistsSilent(vmDir)

        let fd = open(diskPath.path, O_RDWR | O_CREAT | O_TRUNC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw DiskImageError.diskCreationFailed("open() failed (errno \(errno))")
        }
        let result = ftruncate(fd, Int64(size))
        close(fd)
        guard result == 0 else {
            throw DiskImageError.diskCreationFailed("ftruncate() failed (errno \(errno))")
        }

        OsaurusPaths.ensureExistsSilent(OsaurusPaths.agentWorkspace(agentId))
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.agentInput(agentId))
        OsaurusPaths.ensureExistsSilent(OsaurusPaths.agentOutput(agentId))
    }

    /// Remove the entire VM directory for an agent (preserves workspace).
    public func removeAgentVM(for agentId: UUID) throws {
        let vmDir = OsaurusPaths.agentVM(agentId)
        if FileManager.default.fileExists(atPath: vmDir.path) {
            try FileManager.default.removeItem(at: vmDir)
        }
    }
}
