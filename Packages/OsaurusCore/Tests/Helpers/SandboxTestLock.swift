//
//  SandboxTestLock.swift
//  OsaurusCoreTests
//
//  Process-wide serialization for tests that mutate sandbox globals:
//  `ToolRegistry` sandbox tools, `SandboxManager.State`,
//  `SandboxToolRegistrar` overrides, or `HostAPIBridgeServer.shared`.
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
}
