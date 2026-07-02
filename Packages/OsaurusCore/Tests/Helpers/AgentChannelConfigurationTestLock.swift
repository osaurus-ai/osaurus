//
//  AgentChannelConfigurationTestLock.swift
//  OsaurusCoreTests
//
//  Process-wide serialization for tests that mutate native Agent Channel
//  configuration override directories. `@Suite(.serialized)` only serializes
//  tests inside one suite, while Discord/Slack/Telegram tests share globals.
//

import Foundation

actor AgentChannelConfigurationTestLock {
    static let shared = AgentChannelConfigurationTestLock()

    private var holder = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !holder {
            holder = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
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

    func run<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
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
