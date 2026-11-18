//
//  SandboxLeaseConflictResolver.swift
//  osaurus
//
//  Only one process can run the sandbox VM. When another one holds it,
//  Start on the Sandbox page offers the fix in place: quit the Osaurus app
//  that owns the VM, or end the processes left holding its lock, then retry.
//

import AppKit

@MainActor
enum SandboxLeaseConflictResolver {
    enum Action: Equatable {
        /// A running Osaurus app owns the VM.
        case quitApp(pid: Int32, name: String)
        /// A non-app Osaurus process (eval runner, CLI) owns the VM.
        case endProcess(pid: Int32, name: String)
        /// The owner is gone but other processes still hold the lock.
        case endOrphans([SandboxVMOwnershipLease.Holder])
        case retry
    }

    nonisolated static func action(
        for owner: SandboxToolRegistrar.LeaseOwner,
        appName: (Int32) -> String?
    ) -> Action {
        switch owner.state {
        case .osaurusAlive:
            guard let pid = owner.holders.first(where: \.isOsaurus)?.pid ?? owner.owner?.pid else { return .retry }
            if let name = appName(pid) { return .quitApp(pid: pid, name: name) }
            let path = owner.holders.first { $0.pid == pid }?.path
            let name = path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? owner.owner?.processName ?? "Osaurus"
            return .endProcess(pid: pid, name: name)
        case .otherAlive, .ownerDeadLockHeld:
            let orphans = owner.orphanHolders
            return orphans.isEmpty ? .retry : .endOrphans(orphans)
        case .current, .unknown:
            return .retry
        }
    }

    static func present(_ owner: SandboxToolRegistrar.LeaseOwner, agentId: UUID) {
        present(owner) { await SandboxToolRegistrar.shared.retryAfterLeaseConflict(for: agentId) }
    }

    /// Who holds the lease right now, for surfaces that hit the conflict
    /// directly (Start on the Sandbox page) rather than through the registrar.
    static func currentOwner() -> SandboxToolRegistrar.LeaseOwner {
        let classified = SandboxVMOwnershipLease.classifyConflict()
        return SandboxToolRegistrar.LeaseOwner(
            state: classified.state,
            owner: SandboxVMOwnershipLease.readOwner(),
            holders: classified.holders
        )
    }

    private static func runningAppName(_ pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid).flatMap { $0.isTerminated ? nil : $0.localizedName }
    }

    /// Who holds the VM and what frees it, in the fix-it dialog's words.
    static func explanation(for owner: SandboxToolRegistrar.LeaseOwner) -> String {
        explanation(for: action(for: owner, appName: runningAppName))
    }

    nonisolated static func explanation(for action: Action) -> String {
        switch action {
        case .quitApp(let pid, let name):
            return L(
                "Only one Osaurus app can run the sandbox at a time. Quit \(name) (process \(String(pid))) to use the sandbox here."
            )
        case .endProcess(let pid, let name):
            return L("\(name) (process \(String(pid))) is running the sandbox. End it to use the sandbox here.")
        case .endOrphans(let holders):
            let list = holders.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent) (\($0.pid))" }
                .joined(separator: ", ")
            return L(
                "The app that ran the sandbox has quit, but these processes still hold it: \(list). End them to use the sandbox here."
            )
        case .retry:
            return L("Osaurus retries automatically when it frees up.")
        }
    }

    static func present(
        _ owner: SandboxToolRegistrar.LeaseOwner,
        retry: @escaping @MainActor @Sendable () async -> Void
    ) {
        let action = action(for: owner, appName: runningAppName)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.informativeText = explanation(for: action)
        switch action {
        case .quitApp(_, let name):
            alert.messageText = L("The sandbox is in use by \(name)")
            alert.addButton(withTitle: L("Quit \(name)"))
        case .endProcess(_, let name):
            alert.messageText = L("The sandbox is in use by \(name)")
            alert.addButton(withTitle: L("End \(name)"))
        case .endOrphans:
            alert.messageText = L("The sandbox is held by leftover processes")
            alert.addButton(withTitle: L("End Processes"))
        case .retry:
            alert.messageText = L("The sandbox is in use by another process")
            alert.addButton(withTitle: L("Retry Now"))
        }
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        switch action {
        case .quitApp(let pid, _):
            NSRunningApplication(processIdentifier: pid)?.terminate()
        case .endProcess(let pid, _):
            kill(pid, SIGTERM)
        case .endOrphans(let holders):
            for holder in holders { kill(holder.pid, SIGTERM) }
        case .retry:
            break
        }
        Task {
            // An app asked to quit may show its own confirmation first.
            let deadline = Date().addingTimeInterval(action == .retry ? 0 : 15)
            while !SandboxVMOwnershipLease.isAvailable(), Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            await retry()
        }
    }
}
