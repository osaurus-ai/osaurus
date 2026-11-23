//
//  SandboxPodOccupancy.swift
//  OsaurusCore
//
//  Main-actor view of who holds the sandbox VM, so task admission can hold
//  a task whose sandbox identity would need a restart while other work runs.
//

import Foundation

public struct SandboxPodSnapshot: Equatable, Sendable {
    public var isRunning: Bool
    /// Agents and workflows (`wf-…`) with a container in the running VM.
    public var members: Set<String>
    /// Members with running work: an exec, a live background job, or an MCP
    /// server with a request open.
    public var busyHolders: Set<String>

    public init(isRunning: Bool = false, members: Set<String> = [], busyHolders: Set<String> = []) {
        self.isRunning = isRunning
        self.members = members
        self.busyHolders = busyHolders
    }

    /// Whether `member` can start now without stopping anyone. It is in the
    /// VM already, or the VM is down (the next boot includes it), or joining
    /// restarts a VM with nothing running.
    public func admits(_ member: String) -> Bool {
        !isRunning || members.contains(member) || busyHolders.isEmpty
    }
}

@MainActor
public final class SandboxPodOccupancy {
    public static let shared = SandboxPodOccupancy()

    public private(set) var snapshot = SandboxPodSnapshot()
    private var listeners: [() -> Void] = []
    private var version = 0

    public func addListener(_ listener: @escaping () -> Void) {
        listeners.append(listener)
    }

    /// `version` orders publishes that hop to the main actor out of order.
    func publish(_ next: SandboxPodSnapshot, version: Int) {
        guard version > self.version else { return }
        self.version = version
        guard next != snapshot else { return }
        // Admission reads only these, so busy-to-busy churn stays quiet.
        let changed =
            next.isRunning != snapshot.isRunning || next.members != snapshot.members
            || next.busyHolders.isEmpty != snapshot.busyHolders.isEmpty
        snapshot = next
        if changed { listeners.forEach { $0() } }
    }
}
