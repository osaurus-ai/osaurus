//
//  RemoteProviderTestLock.swift
//  OsaurusCoreTests
//
//  Process-wide serialization for tests that mutate `RemoteProviderManager.shared`
//  or assert on `ModelPickerItemCache.shared` while remote-provider notifications
//  are in flight. `@Suite(.serialized)` only serializes tests inside one suite.
//

import Foundation

actor RemoteProviderTestLock {
    static let shared = RemoteProviderTestLock()

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
