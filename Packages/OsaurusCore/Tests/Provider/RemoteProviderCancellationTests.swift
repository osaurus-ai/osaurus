//
//  RemoteProviderCancellationTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Remote provider cancellation ownership")
struct RemoteProviderCancellationTests {
    @Test("consumer termination before URLSession task creation still cancels the task")
    func cancellationBeforeStore() {
        let box = RemoteProviderService.LiveURLSessionTaskBox()
        let task = RecordingURLSessionTask()

        box.cancel()
        box.store(task)

        #expect(task.cancelCount == 1)
    }

    @Test("consumer termination cancels a stored URLSession task exactly once")
    func cancellationAfterStore() {
        let box = RemoteProviderService.LiveURLSessionTaskBox()
        let task = RecordingURLSessionTask()

        box.store(task)
        box.cancel()
        box.cancel()

        #expect(task.cancelCount == 1)
    }
}

private final class RecordingURLSessionTask: URLSessionTask, @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations = 0

    var cancelCount: Int {
        lock.withLock { cancellations }
    }

    override func cancel() {
        lock.withLock { cancellations += 1 }
    }
}
