//
//  SandboxResumableDownloaderTests.swift
//  OsaurusCoreTests
//
//  Contract tests for the resumable runtime-asset downloader: resume
//  request construction (Range/If-Range only with a validator), the
//  append-vs-restart decision on the server's response, persisted
//  partial-state round-trips, and the fail-closed hashing helper.
//

#if os(macOS)

    import CryptoKit
    import Foundation
    import Testing

    @testable import OsaurusCore

    @Suite("SandboxResumableDownloader")
    struct SandboxResumableDownloaderTests {

        private func tempDestination() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("resumable-\(UUID().uuidString)")
                .appendingPathComponent("artifact.bin")
        }

        // MARK: - Request construction

        @Test
        func freshDownload_hasNoRangeHeaders() {
            let request = SandboxResumableDownloader.makeRequest(
                url: URL(string: "https://example.com/blob")!,
                resumeOffset: 0,
                etag: "\"abc\"",
                allowsConstrainedNetwork: true
            )
            #expect(request.value(forHTTPHeaderField: "Range") == nil)
            #expect(request.value(forHTTPHeaderField: "If-Range") == nil)
        }

        @Test
        func resumeWithValidator_attachesRangeAndIfRange() {
            let request = SandboxResumableDownloader.makeRequest(
                url: URL(string: "https://example.com/blob")!,
                resumeOffset: 1_048_576,
                etag: "\"abc\"",
                allowsConstrainedNetwork: true
            )
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=1048576-")
            #expect(request.value(forHTTPHeaderField: "If-Range") == "\"abc\"")
        }

        @Test
        func resumeWithoutValidator_restartsFromZero() {
            // No ETag captured for the partial bytes: a ranged request
            // could splice two different files, so we must not send one.
            let request = SandboxResumableDownloader.makeRequest(
                url: URL(string: "https://example.com/blob")!,
                resumeOffset: 4096,
                etag: nil,
                allowsConstrainedNetwork: true
            )
            #expect(request.value(forHTTPHeaderField: "Range") == nil)
            #expect(request.value(forHTTPHeaderField: "If-Range") == nil)
        }

        @Test
        func constrainedNetworkPreference_isApplied() {
            let request = SandboxResumableDownloader.makeRequest(
                url: URL(string: "https://example.com/blob")!,
                resumeOffset: 0,
                etag: nil,
                allowsConstrainedNetwork: false
            )
            #expect(request.allowsConstrainedNetworkAccess == false)
        }

        // MARK: - Response action

        @Test
        func partialContent_appends() {
            #expect(
                SandboxResumableDownloader.action(forStatus: 206, resumeOffset: 100) == .append
            )
        }

        @Test
        func fullContent_restartsEvenWithPartialBytes() {
            // Server ignored the range (validator failed / no support):
            // the partial file must be truncated, not appended to.
            #expect(
                SandboxResumableDownloader.action(forStatus: 200, resumeOffset: 100) == .restart
            )
        }

        @Test
        func unexpected206WithoutResume_isTreatedAsRestart() {
            #expect(
                SandboxResumableDownloader.action(forStatus: 206, resumeOffset: 0) == .restart
            )
        }

        @Test
        func errorStatus_fails() {
            #expect(
                SandboxResumableDownloader.action(forStatus: 404, resumeOffset: 100)
                    == .fail(status: 404)
            )
        }

        // MARK: - Persisted resume state

        @Test
        func resumeState_roundTripsForMatchingSource() throws {
            let destination = tempDestination()
            let dir = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let partial = SandboxResumableDownloader.partialURL(for: destination)
            try Data(repeating: 0xAA, count: 2048).write(to: partial)
            let meta = SandboxResumableDownloader.ResumeMetadata(
                sourceURL: "https://example.com/blob",
                etag: "\"v1\"",
                totalBytes: 10_000
            )
            try JSONEncoder().encode(meta)
                .write(to: SandboxResumableDownloader.metadataURL(for: destination))

            let state = SandboxResumableDownloader.resumeState(
                destination: destination,
                sourceURL: "https://example.com/blob"
            )
            #expect(state.offset == 2048)
            #expect(state.metadata == meta)
        }

        @Test
        func resumeState_ignoresPartialFromDifferentSource() throws {
            let destination = tempDestination()
            let dir = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let partial = SandboxResumableDownloader.partialURL(for: destination)
            try Data(repeating: 0xAA, count: 2048).write(to: partial)
            let meta = SandboxResumableDownloader.ResumeMetadata(
                sourceURL: "https://mirror-a.example.com/blob"
            )
            try JSONEncoder().encode(meta)
                .write(to: SandboxResumableDownloader.metadataURL(for: destination))

            let state = SandboxResumableDownloader.resumeState(
                destination: destination,
                sourceURL: "https://mirror-b.example.com/blob"
            )
            #expect(state.offset == 0)
            #expect(state.metadata == nil)
        }

        @Test
        func resumeState_withoutPartialFile_startsFresh() {
            let state = SandboxResumableDownloader.resumeState(
                destination: tempDestination(),
                sourceURL: "https://example.com/blob"
            )
            #expect(state.offset == 0)
            #expect(state.metadata == nil)
        }

        // MARK: - Hashing

        @Test
        func sha256Hex_matchesCryptoKit() throws {
            let bytes = Data((0 ..< 4096).map { _ in UInt8.random(in: 0 ... 255) })
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hash-\(UUID().uuidString).bin")
            try bytes.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            let actual = try SandboxResumableDownloader.sha256Hex(of: url, maxBytes: 1 << 20)
            #expect(actual == expected)
        }

        @Test
        func sha256Hex_enforcesSizeCap() throws {
            let bytes = Data(repeating: 0x11, count: 4096)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hash-cap-\(UUID().uuidString).bin")
            try bytes.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }

            #expect(throws: SandboxResumableDownloader.DownloadError.self) {
                _ = try SandboxResumableDownloader.sha256Hex(of: url, maxBytes: 1024)
            }
        }

        // MARK: - Disk preflight

        @Test
        func diskPreflight_passesForTinyRequirement() throws {
            // 1 KiB remaining on the temp volume must always pass.
            try SandboxResumableDownloader.checkDiskSpace(
                destination: tempDestination(),
                remainingBytes: 1024,
                fallbackBytes: 1024
            )
        }

        @Test
        func diskPreflight_failsForAbsurdRequirement() {
            #expect(throws: SandboxResumableDownloader.DownloadError.self) {
                try SandboxResumableDownloader.checkDiskSpace(
                    destination: FileManager.default.temporaryDirectory
                        .appendingPathComponent("never-created.bin"),
                    remainingBytes: Int64.max / 2,
                    fallbackBytes: 0
                )
            }
        }
    }

    @Suite("Sandbox warm-boot cache key")
    struct SandboxWarmBootStampTests {

        /// The image digest currently pinned by the binary. Read via the
        /// stamp helper itself: a config carrying both current values
        /// must validate...
        @Test
        func matchingDigestAndRuntimeFormat_isWarm() {
            var config = SandboxConfiguration.default
            config.lastBootedImageDigest = SandboxManager.pinnedContainerImageForTesting
            config.lastRuntimeFormatVersion = SandboxRuntimeAssets.runtimeFormatVersion
            #expect(SandboxManager.warmBootStampValid(config: config))
        }

        /// ...while a stale image digest (app update rotated the pin)
        /// must force the cold path...
        @Test
        func staleImageDigest_forcesCold() {
            var config = SandboxConfiguration.default
            config.lastBootedImageDigest = "ghcr.io/osaurus-ai/sandbox@sha256:" + String(repeating: "0", count: 64)
            config.lastRuntimeFormatVersion = SandboxRuntimeAssets.runtimeFormatVersion
            #expect(!SandboxManager.warmBootStampValid(config: config))
        }

        /// ...and a runtime-format change (SDK/initfs upgrade) must force
        /// the cold path even when the image digest still matches, so an
        /// incompatible cached rootfs never enters a doomed warm boot.
        @Test
        func staleRuntimeFormat_forcesCold() {
            var config = SandboxConfiguration.default
            config.lastBootedImageDigest = SandboxManager.pinnedContainerImageForTesting
            config.lastRuntimeFormatVersion = "cz-0.31/raw-initfs"
            #expect(!SandboxManager.warmBootStampValid(config: config))
        }

        /// Installs that pre-date the runtime stamp (nil) are treated as
        /// cold exactly once after upgrade.
        @Test
        func missingRuntimeFormat_forcesCold() {
            var config = SandboxConfiguration.default
            config.lastBootedImageDigest = SandboxManager.pinnedContainerImageForTesting
            config.lastRuntimeFormatVersion = nil
            #expect(!SandboxManager.warmBootStampValid(config: config))
        }
    }

#endif
