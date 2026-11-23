//
//  ToolPermissionPromptTestLock.swift
//  OsaurusCoreTests
//
//  Process-wide serialization for tests that present cards through
//  `ToolPermissionPromptService.presentationOverrideForTests`. The prompt
//  queue has one presented slot shared by the whole process, and
//  `resetForTesting()` denies every outstanding card, so two suites driving
//  it in parallel deny or queue behind each other's cards.
//
//  Apply `.toolPermissionPromptQueue` to the suite. It is always the
//  outermost lock: tests take `DynamicToolProbeFixture` and other locks
//  inside it.
//

import Foundation
import Testing

actor ToolPermissionPromptTestLock {
    static let shared = ToolPermissionPromptTestLock()

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

    static func run(_ body: () async throws -> Void) async rethrows {
        await shared.acquire()
        do {
            try await body()
        } catch {
            await shared.release()
            throw error
        }
        await shared.release()
    }
}

struct ToolPermissionPromptQueueTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        guard testCase != nil else { return try await function() }
        try await ToolPermissionPromptTestLock.run(function)
    }
}

extension Trait where Self == ToolPermissionPromptQueueTrait {
    /// Serializes this suite's tests with every other suite that drives the
    /// shared tool permission prompt queue.
    static var toolPermissionPromptQueue: Self { Self() }
}
