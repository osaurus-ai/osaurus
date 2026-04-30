//
//  SandboxTestLock.swift
//  OsaurusCoreTests
//
//  Process-wide serialization for tests that mutate sandbox-adjacent globals:
//  `ToolRegistry` sandbox tools, `SandboxManager.State`,
//  `SandboxToolRegistrar` overrides, `HostAPIBridgeServer.shared`,
//  or synthetic `AgentManager.shared` agents used to resolve sandbox modes.
//

import Foundation

actor SandboxTestLock {
    static let shared = SandboxTestLock()

    private var holder = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !holder {
            holder = true
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters.append(cont)
        }
    }

    private func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            holder = false
        }
    }

    func run<T: Sendable>(
        _ body: @MainActor @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire()
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    /// Acquire `StoragePathsTestLock` and `SandboxTestLock` in the canonical
    /// (Storage outside, Sandbox inside) order. Required for any test that
    /// touches `AgentManager.shared`, because `AgentStore.save/loadAll` reads
    /// `OsaurusPaths.overrideRoot` — a storage-path-rewriting suite can flip
    /// it between `add(...)`'s save and refresh and silently drop the
    /// just-added agent from the in-memory `agents` array.
    static func runWithStoragePaths<T: Sendable>(
        _ body: @MainActor @Sendable () async throws -> T
    ) async rethrows -> T {
        try await StoragePathsTestLock.shared.run {
            try await Self.shared.run(body)
        }
    }
}
