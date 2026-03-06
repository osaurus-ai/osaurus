//
//  VMProvisioner.swift
//  osaurus
//
//  Scripts the unattended Alpine Linux installation and guest configuration
//  through the serial console pipes. Runs in two phases:
//    Phase 1 (install): Boot from ISO, run setup-alpine, poweroff.
//    Phase 2 (configure): Boot from disk, set up fstab/python/shim, mark done.
//

import Foundation

public enum VMProvisionError: Error, LocalizedError {
    case timeout(String)
    case unexpectedOutput(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let ctx): return "Provisioning timeout: \(ctx)"
        case .unexpectedOutput(let ctx): return "Unexpected console output: \(ctx)"
        case .installFailed(let ctx): return "Install failed: \(ctx)"
        }
    }
}

public final class VMProvisioner: @unchecked Sendable {
    private let inputPipe: Pipe
    private let outputPipe: Pipe
    private let agentId: UUID

    private let ioQueue = DispatchQueue(label: "com.osaurus.provisioner.io", qos: .userInitiated)

    public init(inputPipe: Pipe, outputPipe: Pipe, agentId: UUID) {
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.agentId = agentId
        setNonBlocking(outputPipe.fileHandleForReading.fileDescriptor)
    }

    /// Set file descriptor to non-blocking mode so reads return EAGAIN instead of blocking.
    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    // MARK: - Phase 1: Install OS + Configure Installed System

    /// Boot from ISO kernel via VZLinuxBootLoader (console=hvc0 gives us serial).
    /// Install Alpine, then mount the installed root and configure it for EFI boot.
    public func installOS() async throws {
        let id = agentId
        await log(id, .installingOS, "Booted with VZLinuxBootLoader (console=hvc0)")
        await log(id, .installingOS, "Waiting for login prompt...")

        try await waitFor("login:", timeout: 120)
        await log(id, .installingOS, "Got login prompt, logging in as root")
        sendLine("root")
        try await waitFor("#", timeout: 15)

        // Write the answers file
        await log(id, .installingOS, "Writing answers file")
        sendLine("cat > /tmp/answers << 'ANSWERS_EOF'")
        for line in Self.answersFileContent.components(separatedBy: "\n") {
            sendLine(line)
        }
        sendLine("ANSWERS_EOF")
        try await waitFor("#", timeout: 10)

        // Run setup-alpine
        await log(id, .installingOS, "Running setup-alpine (this takes 1-2 minutes)...")
        sendLine("setup-alpine -f /tmp/answers")
        try await waitFor("Installation is complete", timeout: 300)
        await log(id, .installingOS, "Installation complete")

        // Now configure the INSTALLED system before rebooting.
        // setup-alpine with DISKOPTS="-m sys /dev/vda" creates:
        //   /dev/vda1 = EFI partition, /dev/vda2 = swap, /dev/vda3 = root (ext4)
        await log(id, .configuringSystem, "Mounting installed root to configure it")
        sendLine("mount /dev/vda3 /mnt")
        try await waitFor("#", timeout: 10)
        sendLine("mount /dev/vda1 /mnt/boot/efi 2>/dev/null; true")
        try await waitFor("#", timeout: 5)

        // Enable getty on hvc0 so EFI boots have serial console login
        await log(id, .configuringSystem, "Enabling serial console on hvc0")
        sendLine("grep -q hvc0 /mnt/etc/inittab || echo 'hvc0::respawn:/sbin/getty 115200 hvc0' >> /mnt/etc/inittab")
        try await waitFor("#", timeout: 5)

        // Add console=hvc0 to GRUB for kernel messages on serial
        sendLine("sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"console=hvc0 /' /mnt/etc/default/grub 2>/dev/null; true")
        try await waitFor("#", timeout: 5)

        // Regenerate GRUB config inside the installed system
        sendLine("mount --bind /dev /mnt/dev && mount --bind /proc /mnt/proc && mount --bind /sys /mnt/sys")
        try await waitFor("#", timeout: 10)
        sendLine("chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg 2>&1; true")
        try await waitFor("#", timeout: 30)

        // Configure VirtioFS mounts
        await log(id, .configuringSystem, "Configuring VirtioFS mounts in installed fstab")
        sendLine("mkdir -p /mnt/workspace /mnt/input /mnt/output")
        try await waitFor("#", timeout: 5)
        sendLine("echo 'workspace /workspace virtiofs rw 0 0' >> /mnt/etc/fstab")
        try await waitFor("#", timeout: 5)
        sendLine("echo 'input /input virtiofs ro 0 0' >> /mnt/etc/fstab")
        try await waitFor("#", timeout: 5)
        sendLine("echo 'output /output virtiofs rw 0 0' >> /mnt/etc/fstab")
        try await waitFor("#", timeout: 5)

        // Install python3 and deploy shim inside the installed system
        await log(id, .deployingShim, "Installing Python 3 in installed system")
        sendLine("chroot /mnt apk add python3 2>&1")
        try await waitFor("#", timeout: 120)

        await log(id, .deployingShim, "Deploying osaurus-host shim")
        sendLine("mkdir -p /mnt/usr/local/bin")
        try await waitFor("#", timeout: 5)
        // The ISO live system has /input mounted via VirtioFS already
        sendLine("mount -t virtiofs input /mnt/input 2>/dev/null; true")
        try await waitFor("#", timeout: 10)
        sendLine("cp /mnt/input/osaurus-host.py /mnt/usr/local/bin/osaurus-host 2>&1; true")
        try await waitFor("#", timeout: 5)
        sendLine("chmod +x /mnt/usr/local/bin/osaurus-host")
        try await waitFor("#", timeout: 5)

        // Write sentinel
        await log(id, .deployingShim, "Writing provisioned sentinel")
        sendLine("touch /mnt/etc/osaurus-provisioned")
        try await waitFor("#", timeout: 5)

        // Clean up mounts and power off
        sendLine("umount -R /mnt 2>/dev/null; true")
        try await waitFor("#", timeout: 10)
        await log(id, .installingOS, "Configuration complete, powering off")
        sendLine("poweroff -f")

        try await waitForDisconnectOrShutdown(timeout: 30)
        await log(id, .installingOS, "VM shut down after install")
    }

    // MARK: - Phase 2: Verify Installed System

    /// After EFI boot from the installed disk, verify the system is working.
    /// The installed system was fully configured in phase 1, so this is just
    /// a health check and a chance to fix anything that didn't stick.
    public func configureSystem() async throws {
        let id = agentId
        await log(id, .configuringSystem, "Waiting for installed system boot...")

        try await waitFor("login:", timeout: 120)
        await log(id, .configuringSystem, "Got login prompt — installed system is working")
        sendLine("root")
        try await waitFor("#", timeout: 15)

        // Verify key components
        sendLine("test -f /etc/osaurus-provisioned && echo PROV_OK || echo PROV_MISSING")
        let provResult = try await waitFor("PROV_", timeout: 5)
        if provResult.contains("PROV_MISSING") {
            await log(id, .configuringSystem, "Warning: provisioned sentinel missing, re-creating")
            sendLine("touch /etc/osaurus-provisioned")
            try await waitFor("#", timeout: 5)
        }

        sendLine("which osaurus-host && echo SHIM_OK || echo SHIM_MISSING")
        let shimResult = try await waitFor("SHIM_", timeout: 5)
        if shimResult.contains("SHIM_MISSING") {
            await log(id, .configuringSystem, "Warning: shim missing, re-deploying")
            sendLine("cp /input/osaurus-host.py /usr/local/bin/osaurus-host 2>&1; true")
            try await waitFor("#", timeout: 5)
            sendLine("chmod +x /usr/local/bin/osaurus-host")
            try await waitFor("#", timeout: 5)
        }

        sendLine("which python3 && echo PY_OK || echo PY_MISSING")
        let pyResult = try await waitFor("PY_", timeout: 5)
        if pyResult.contains("PY_MISSING") {
            await log(id, .configuringSystem, "Warning: python3 missing, installing")
            sendLine("apk add python3 2>&1")
            try await waitFor("#", timeout: 120)
        }

        await log(id, .ready, "Provisioning verified — system is ready")
    }

    // MARK: - Serial Console I/O

    /// Send text followed by a carriage return (Enter key for serial terminals).
    private func sendLine(_ text: String) {
        let data = Data((text + "\r").utf8)
        inputPipe.fileHandleForWriting.write(data)
    }

    /// Send raw bytes without any line terminator (for single keystrokes).
    private func sendRaw(_ text: String) {
        let data = Data(text.utf8)
        inputPipe.fileHandleForWriting.write(data)
    }

    @discardableResult
    private func waitFor(_ pattern: String, timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        let agentId = self.agentId

        return try await withCheckedThrowingContinuation { continuation in
            ioQueue.async { [self] in
                var accumulated = ""
                var totalBytesRead = 0
                var readAttempts = 0
                let fd = self.outputPipe.fileHandleForReading.fileDescriptor

                // Verify fd is valid and non-blocking
                let flags = fcntl(fd, F_GETFL)
                let isNonBlocking = (flags & O_NONBLOCK) != 0
                NSLog("[VMProvisioner] waitFor('%@') fd=%d flags=0x%x nonblock=%d", pattern, fd, flags, isNonBlocking ? 1 : 0)

                while Date() < deadline {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    let bytesRead = read(fd, &buffer, buffer.count)
                    readAttempts += 1

                    if bytesRead > 0 {
                        totalBytesRead += bytesRead
                        let text = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
                        accumulated += text

                        let cleanLines = text.components(separatedBy: .newlines)
                            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        for line in cleanLines {
                            Task { @MainActor in
                                let currentPhase = VMBootLog.shared.phase[agentId] ?? .booting
                                VMBootLog.shared.append(agentId: agentId, phase: currentPhase, message: line)
                            }
                        }

                        if accumulated.contains(pattern) {
                            NSLog("[VMProvisioner] Found '%@' after %d bytes, %d attempts", pattern, totalBytesRead, readAttempts)
                            continuation.resume(returning: accumulated)
                            return
                        }
                    } else {
                        // Log first few EAGAIN results for diagnostics
                        if readAttempts <= 3 {
                            let err = errno
                            NSLog("[VMProvisioner] read() returned %d, errno=%d (%s), attempt #%d",
                                  bytesRead, err, String(cString: strerror(err)), readAttempts)
                        }
                        Thread.sleep(forTimeInterval: 0.25)
                    }
                }
                NSLog("[VMProvisioner] TIMEOUT waiting for '%@': %d bytes total, %d attempts", pattern, totalBytesRead, readAttempts)
                continuation.resume(throwing: VMProvisionError.timeout(
                    "Timed out waiting for '\(pattern)' (\(totalBytesRead) bytes received in \(readAttempts) attempts)"
                ))
            }
        }
    }

    private func waitForDisconnectOrShutdown(timeout: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
    }

    // MARK: - Logging Helper

    @MainActor
    private func log(_ agentId: UUID, _ phase: VMProvisionPhase, _ message: String) {
        VMBootLog.shared.setPhase(agentId: agentId, phase)
        VMBootLog.shared.append(agentId: agentId, phase: phase, message: message)
    }

    // MARK: - Answers File

    static let answersFileContent = """
    KEYMAPOPTS="us us"
    HOSTNAMEOPTS="-n osaurus"
    INTERFACESOPTS="auto lo
    iface lo inet loopback

    auto eth0
    iface eth0 inet dhcp
    "
    TIMEZONEOPTS="-z UTC"
    PROXYOPTS="none"
    APKREPOSOPTS="-1"
    SSHDOPTS="-c none"
    NTPOPTS="-c none"
    DISKOPTS="-m sys /dev/vda"
    """
}
