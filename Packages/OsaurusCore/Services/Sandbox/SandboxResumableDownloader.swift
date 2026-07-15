//
//  SandboxResumableDownloader.swift
//  osaurus
//
//  Resumable, mirror-failover download service for the sandbox's large
//  runtime artifacts (kernel tarball fallback, initfs blob fallback).
//
//  Unlike `URLSession.download(from:)` — whose temp file is discarded
//  when the app quits or the connection drops — this streams into a
//  persisted `<dest>.partial` file with an ETag/Range sidecar, so an
//  interrupted 200 MiB download resumes from where it stopped instead
//  of restarting from byte zero. Integrity is still fail-closed: the
//  completed file must match the expected SHA-256 before it is moved
//  into place.
//

import CryptoKit
import Foundation

#if os(macOS)

    public final class SandboxResumableDownloader: Sendable {
        /// One mirror plus the SHA-256 the final bytes must match.
        public struct Source: Sendable {
            public let url: String
            public let expectedSHA256: String

            public init(url: String, expectedSHA256: String) {
                self.url = url
                self.expectedSHA256 = expectedSHA256
            }
        }

        /// Sidecar persisted next to the partial file. A resume is only
        /// attempted when the stored source URL matches and the server
        /// validator (ETag) is still available to guard with `If-Range`.
        public struct ResumeMetadata: Codable, Equatable, Sendable {
            public var sourceURL: String
            public var etag: String?
            public var totalBytes: Int64?

            public init(sourceURL: String, etag: String? = nil, totalBytes: Int64? = nil) {
                self.sourceURL = sourceURL
                self.etag = etag
                self.totalBytes = totalBytes
            }
        }

        public enum DownloadError: Error, LocalizedError {
            case httpStatus(Int)
            case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
            case sizeCapExceeded(bytes: Int64, cap: Int64)
            case allSourcesFailed(String)
            case integrityMismatch(expected: String, actual: String)

            public var errorDescription: String? {
                switch self {
                case .httpStatus(let code):
                    return "HTTP \(code)"
                case .insufficientDiskSpace(let required, let available):
                    return
                        "Not enough disk space for the sandbox runtime download (need \(required) bytes, have \(available))"
                case .sizeCapExceeded(let bytes, let cap):
                    return "Download exceeded size cap (\(bytes) > \(cap) bytes)"
                case .allSourcesFailed(let detail):
                    return "Download failed: \(detail)"
                case .integrityMismatch(let expected, let actual):
                    return "SHA-256 mismatch: expected \(expected), got \(actual)"
                }
            }
        }

        /// Byte-progress callback: (bytesSoFar, totalExpectedOrZero).
        public typealias Progress = @Sendable (Int64, Int64) -> Void

        private let maxBytes: Int64
        private let allowsConstrainedNetwork: Bool

        public init(maxBytes: Int, allowsConstrainedNetwork: Bool = true) {
            self.maxBytes = Int64(maxBytes)
            self.allowsConstrainedNetwork = allowsConstrainedNetwork
        }

        // MARK: - Pure helpers (unit-tested without a network)

        public static func partialURL(for destination: URL) -> URL {
            destination.appendingPathExtension("partial")
        }

        public static func metadataURL(for destination: URL) -> URL {
            destination.appendingPathExtension("partial-meta.json")
        }

        /// Build the resume request for a source. Attaches `Range` +
        /// `If-Range` only when we have both existing bytes and the ETag
        /// captured when those bytes were written — without the validator
        /// a mirror rotation could silently splice two different files.
        public static func makeRequest(
            url: URL,
            resumeOffset: Int64,
            etag: String?,
            allowsConstrainedNetwork: Bool
        ) -> URLRequest {
            var request = URLRequest(url: url)
            request.allowsConstrainedNetworkAccess = allowsConstrainedNetwork
            if resumeOffset > 0, let etag, !etag.isEmpty {
                request.setValue("bytes=\(resumeOffset)-", forHTTPHeaderField: "Range")
                request.setValue(etag, forHTTPHeaderField: "If-Range")
            }
            return request
        }

        /// Decide how to treat the server's response to a (possibly
        /// ranged) request. `206` continues the partial file; `200` means
        /// the validator failed or ranges are unsupported, so the partial
        /// restarts from zero; anything else is a hard failure for this
        /// source.
        public enum ResponseAction: Equatable, Sendable {
            case append
            case restart
            case fail(status: Int)
        }

        public static func action(forStatus status: Int, resumeOffset: Int64) -> ResponseAction {
            switch status {
            case 206 where resumeOffset > 0:
                return .append
            case 200 ... 299:
                return .restart
            default:
                return .fail(status: status)
            }
        }

        /// Read the persisted resume state for `destination` against a
        /// specific source URL. Returns byte offset 0 when there is no
        /// usable partial (missing, different source, unreadable meta).
        public static func resumeState(
            destination: URL,
            sourceURL: String
        ) -> (offset: Int64, metadata: ResumeMetadata?) {
            let fm = FileManager.default
            let partial = partialURL(for: destination)
            guard fm.fileExists(atPath: partial.path),
                let attrs = try? fm.attributesOfItem(atPath: partial.path),
                let size = (attrs[.size] as? NSNumber)?.int64Value,
                size > 0,
                let data = try? Data(contentsOf: metadataURL(for: destination)),
                let meta = try? JSONDecoder().decode(ResumeMetadata.self, from: data),
                meta.sourceURL == sourceURL
            else {
                return (0, nil)
            }
            return (size, meta)
        }

        /// Preflight free-space check on the destination volume. Uses the
        /// expected remaining bytes plus a safety margin; when the total
        /// is unknown the size cap is used as the conservative bound.
        public static func checkDiskSpace(
            destination: URL,
            remainingBytes: Int64?,
            fallbackBytes: Int64
        ) throws {
            let needed = (remainingBytes ?? fallbackBytes) + 64 * 1024 * 1024
            let dir = destination.deletingLastPathComponent()
            guard
                let values = try? dir.resourceValues(forKeys: [
                    .volumeAvailableCapacityForImportantUsageKey
                ]),
                let available = values.volumeAvailableCapacityForImportantUsage
            else {
                return  // Can't measure — don't block the download on it.
            }
            if available < needed {
                throw DownloadError.insufficientDiskSpace(
                    requiredBytes: needed,
                    availableBytes: available
                )
            }
        }

        // MARK: - Download

        /// Download from the first source that succeeds, resuming any
        /// persisted partial state, and verify the SHA-256 before moving
        /// the file to `destination`. Integrity failures abort the whole
        /// operation (no mirror failover) — a real upstream compromise
        /// affects every mirror and silent fallback would hide it.
        public func download(
            from sources: [Source],
            to destination: URL,
            progress: Progress? = nil
        ) async throws {
            var lastError: Error?
            for source in sources {
                guard let url = URL(string: source.url) else { continue }
                do {
                    try await downloadSingle(source: source, url: url, destination: destination, progress: progress)
                    return
                } catch let error as DownloadError {
                    switch error {
                    case .integrityMismatch, .sizeCapExceeded, .insufficientDiskSpace:
                        throw error
                    default:
                        lastError = error
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
                debugLog(
                    "[SandboxDownload] Source failed (\(source.url)): \(lastError?.localizedDescription ?? "?")"
                )
            }
            throw DownloadError.allSourcesFailed(
                lastError?.localizedDescription ?? "all URLs failed"
            )
        }

        private func downloadSingle(
            source: Source,
            url: URL,
            destination: URL,
            progress: Progress?
        ) async throws {
            let fm = FileManager.default
            let partial = Self.partialURL(for: destination)
            let metaURL = Self.metadataURL(for: destination)
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let (resumeOffset, meta) = Self.resumeState(
                destination: destination,
                sourceURL: source.url
            )
            let remaining = meta?.totalBytes.map { max(0, $0 - resumeOffset) }
            try Self.checkDiskSpace(
                destination: destination,
                remainingBytes: remaining,
                fallbackBytes: maxBytes
            )

            if !fm.fileExists(atPath: partial.path) {
                fm.createFile(atPath: partial.path, contents: nil)
            }

            let request = Self.makeRequest(
                url: url,
                resumeOffset: resumeOffset,
                etag: meta?.etag,
                allowsConstrainedNetwork: allowsConstrainedNetwork
            )
            let session = Self.makeSession()
            defer { session.finishTasksAndInvalidate() }

            let (bytesStream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DownloadError.httpStatus(0)
            }

            var offset = resumeOffset
            switch Self.action(forStatus: http.statusCode, resumeOffset: resumeOffset) {
            case .append:
                break
            case .restart:
                offset = 0
            case .fail(let status):
                throw DownloadError.httpStatus(status)
            }

            // Persist the validator + total for the bytes we're about to
            // write, so the *next* attempt (after a crash / quit) can
            // resume against the same entity.
            let total: Int64? = {
                let length = http.expectedContentLength
                guard length > 0 else { return meta?.totalBytes }
                return offset + length
            }()
            let newMeta = ResumeMetadata(
                sourceURL: source.url,
                etag: http.value(forHTTPHeaderField: "ETag"),
                totalBytes: total
            )
            if let encoded = try? JSONEncoder().encode(newMeta) {
                try? encoded.write(to: metaURL, options: .atomic)
            }

            let handle = try FileHandle(forWritingTo: partial)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(offset))
            try handle.seekToEnd()

            var buffer = Data()
            buffer.reserveCapacity(512 * 1024)
            var written = offset
            var lastReport = Date.distantPast
            for try await byte in bytesStream {
                buffer.append(byte)
                if buffer.count >= 512 * 1024 {
                    try handle.write(contentsOf: buffer)
                    written += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    if written > maxBytes {
                        throw DownloadError.sizeCapExceeded(bytes: written, cap: maxBytes)
                    }
                    let now = Date()
                    if now.timeIntervalSince(lastReport) > 0.1 {
                        lastReport = now
                        progress?(written, total ?? 0)
                    }
                }
                try Task.checkCancellation()
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
            }
            try handle.close()
            progress?(written, total ?? written)
            if written > maxBytes {
                throw DownloadError.sizeCapExceeded(bytes: written, cap: maxBytes)
            }

            // Fail-closed integrity check before the file is installed.
            let actual = try Self.sha256Hex(of: partial, maxBytes: maxBytes)
            guard actual == source.expectedSHA256.lowercased() else {
                try? fm.removeItem(at: partial)
                try? fm.removeItem(at: metaURL)
                throw DownloadError.integrityMismatch(
                    expected: source.expectedSHA256.lowercased(),
                    actual: actual
                )
            }

            try? fm.removeItem(at: destination)
            try fm.moveItem(at: partial, to: destination)
            try? fm.removeItem(at: metaURL)
        }

        /// Session factory for artifact downloads. Routed through
        /// `GlobalProxySettings` so a user-configured proxy applies to
        /// runtime asset downloads the same as every other network call.
        static func makeSession() -> URLSession {
            GlobalProxySettings.makeSession(base: .default)
        }

        /// Chunked SHA-256 (1 MiB reads) with a byte cap.
        static func sha256Hex(of url: URL, maxBytes: Int64) throws -> String {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            var totalRead: Int64 = 0
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                totalRead += Int64(chunk.count)
                if totalRead > maxBytes {
                    throw DownloadError.sizeCapExceeded(bytes: totalRead, cap: maxBytes)
                }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

#endif
