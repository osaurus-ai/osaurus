//
//  RemoteProviderConnectRetryTests.swift
//  osaurusTests
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("RemoteProviderService connect retry")
struct RemoteProviderConnectRetryTests {

    @Test func connectWithRetry_stopsBeforeFirstAttemptWhenCancelled() async throws {
        let session = URLSession(configuration: .ephemeral)
        session.invalidateAndCancel()

        let request = URLRequest(url: try #require(URL(string: "http://127.0.0.1:9/v1/chat/completions")))

        do {
            _ = try await RemoteProviderService.connectWithRetry(
                session: session,
                urlRequest: request,
                isCancelled: { true }
            )
            Issue.record("Expected connectWithRetry to throw before using an invalidated URLSession.")
        } catch is CancellationError {
            // Expected: the invalidation guard fires before URLSession.bytes(for:).
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
    }
}
