import Foundation
import Testing

@testable import OsaurusCore

/// Coverage for the transfer retry policy that decides whether a failed
/// file download is retried and how long to wait first. These are the
/// static, side-effect-free helpers behind the concurrent download loop.
struct ModelDownloadRetryPolicyTests {

    // MARK: - isRetryableTransferError

    @Test func retriesThrottlingAndServerErrors() {
        for code in [408, 429, 500, 502, 503, 599] {
            let error = DirectDownloader.HTTPStatusError(statusCode: code, retryAfterSeconds: nil)
            #expect(
                ModelDownloadService.isRetryableTransferError(error),
                "expected HTTP \(code) to be retryable"
            )
        }
    }

    @Test func doesNotRetryClientErrors() {
        for code in [400, 401, 403, 404, 410] {
            let error = DirectDownloader.HTTPStatusError(statusCode: code, retryAfterSeconds: nil)
            #expect(
                !ModelDownloadService.isRetryableTransferError(error),
                "expected HTTP \(code) to be permanent"
            )
        }
    }

    @Test func retriesTransientNetworkErrors() {
        let codes: [URLError.Code] = [
            .timedOut, .networkConnectionLost, .cannotConnectToHost,
            .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
            // The downloader's size-mismatch (truncated transfer) surfaces here.
            .cannotDecodeContentData,
        ]
        for code in codes {
            #expect(
                ModelDownloadService.isRetryableTransferError(URLError(code)),
                "expected \(code) to be retryable"
            )
        }
    }

    @Test func doesNotRetryPermanentNetworkErrors() {
        for code in [URLError.Code.badURL, .unsupportedURL, .userAuthenticationRequired] {
            #expect(
                !ModelDownloadService.isRetryableTransferError(URLError(code)),
                "expected \(code) to be permanent"
            )
        }
    }

    @Test func doesNotRetryPauseOrCancellation() {
        let pause = DirectDownloader.PauseInfo(resumeData: nil, bytesDownloaded: 0)
        #expect(!ModelDownloadService.isRetryableTransferError(pause))
        #expect(!ModelDownloadService.isRetryableTransferError(CancellationError()))
    }

    @Test func doesNotRetryUnknownErrors() {
        struct Custom: Error {}
        #expect(!ModelDownloadService.isRetryableTransferError(Custom()))
    }

    // MARK: - transferRetryDelay

    @Test func backsOffExponentiallyWhenNoRetryAfter() {
        let error = URLError(.timedOut)
        #expect(ModelDownloadService.transferRetryDelay(attempt: 1, error: error) == 1)
        #expect(ModelDownloadService.transferRetryDelay(attempt: 2, error: error) == 2)
        #expect(ModelDownloadService.transferRetryDelay(attempt: 3, error: error) == 4)
    }

    @Test func capsExponentialBackoff() {
        // 2^(attempt-1) grows past the 15s ceiling by attempt 5.
        let error = URLError(.timedOut)
        #expect(ModelDownloadService.transferRetryDelay(attempt: 5, error: error) == 15)
        #expect(ModelDownloadService.transferRetryDelay(attempt: 9, error: error) == 15)
    }

    @Test func honorsServerRetryAfter() {
        let error = DirectDownloader.HTTPStatusError(statusCode: 429, retryAfterSeconds: 30)
        #expect(ModelDownloadService.transferRetryDelay(attempt: 1, error: error) == 30)
    }

    @Test func capsServerRetryAfter() {
        let error = DirectDownloader.HTTPStatusError(statusCode: 503, retryAfterSeconds: 900)
        #expect(ModelDownloadService.transferRetryDelay(attempt: 1, error: error) == 120)
    }

    @Test func ignoresNonPositiveRetryAfter() {
        // A zero/absent Retry-After falls back to exponential backoff.
        let zero = DirectDownloader.HTTPStatusError(statusCode: 429, retryAfterSeconds: 0)
        #expect(ModelDownloadService.transferRetryDelay(attempt: 2, error: zero) == 2)
        let absent = DirectDownloader.HTTPStatusError(statusCode: 429, retryAfterSeconds: nil)
        #expect(ModelDownloadService.transferRetryDelay(attempt: 2, error: absent) == 2)
    }

    // MARK: - HTTPStatusError

    @Test func statusErrorDescribesItsCode() {
        let error = DirectDownloader.HTTPStatusError(statusCode: 429, retryAfterSeconds: nil)
        #expect(error.errorDescription == "HTTP 429")
    }

    @Test func allowsBoundedRetryAttempts() {
        // One initial try plus retries; a positive, small bound so a stuck
        // file can't loop forever.
        #expect(ModelDownloadService.maxTransferAttempts >= 2)
        #expect(ModelDownloadService.maxTransferAttempts <= 6)
    }
}
