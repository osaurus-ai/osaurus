//
//  SandboxArtifactIntegrityTests.swift
//  OsaurusCoreTests
//
//  Verifies the SHA-256 verification SandboxManager uses for downloaded
//  kernel/initfs blobs. The integrity check is the only thing standing
//  between an upstream (CDN, registry, release-host) compromise and
//  an attacker-chosen guest filesystem, so the failure paths must be
//  fail-closed and unambiguous.
//

#if os(macOS)

    import CryptoKit
    import Foundation
    import Testing

    @testable import OsaurusCore

    @Suite("SandboxManager.verifySHA256")
    struct SandboxArtifactIntegrityTests {

        /// Helper: write some bytes to a temp file the test can clean up.
        private func tempFile(containing data: Data) throws -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("artifact-\(UUID().uuidString).bin")
            try data.write(to: url)
            return url
        }

        private func sha256Hex(of data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        @Test
        func matchingDigest_passesSilently() throws {
            let bytes = Data((0 ..< 4096).map { _ in UInt8.random(in: 0 ... 255) })
            let url = try tempFile(containing: bytes)
            defer { try? FileManager.default.removeItem(at: url) }

            // Should not throw.
            try SandboxManager.verifySHA256(
                of: url,
                expected: sha256Hex(of: bytes),
                maxBytes: 1 << 20
            )
        }

        @Test
        func mismatchedDigest_throwsIntegrityCheckFailed() throws {
            let bytes = Data(repeating: 0xAB, count: 1024)
            let url = try tempFile(containing: bytes)
            defer { try? FileManager.default.removeItem(at: url) }

            // A digest that's the right shape but for different bytes.
            let wrongDigest = String(repeating: "0", count: 64)
            do {
                try SandboxManager.verifySHA256(
                    of: url,
                    expected: wrongDigest,
                    maxBytes: 1 << 20
                )
                Issue.record("Expected verifySHA256 to throw on mismatched digest")
            } catch let SandboxError.integrityCheckFailed(reason) {
                #expect(reason.contains("SHA-256 mismatch"))
            } catch {
                Issue.record("Expected SandboxError.integrityCheckFailed, got \(error)")
            }
        }

        @Test
        func malformedExpectedDigest_throwsIntegrityCheckFailed() throws {
            let url = try tempFile(containing: Data([0x01, 0x02, 0x03]))
            defer { try? FileManager.default.removeItem(at: url) }

            // Not 64 hex chars — caught structurally before we hash anything,
            // so a typo in the constants table fails loudly instead of
            // silently letting an unverified file through.
            do {
                try SandboxManager.verifySHA256(
                    of: url,
                    expected: "not-a-hex-digest",
                    maxBytes: 1 << 20
                )
                Issue.record("Expected verifySHA256 to throw on malformed digest")
            } catch let SandboxError.integrityCheckFailed(reason) {
                #expect(reason.lowercased().contains("malformed"))
            } catch {
                Issue.record("Expected SandboxError.integrityCheckFailed, got \(error)")
            }
        }

        @Test
        func oversizedFile_throwsIntegrityCheckFailed() throws {
            let bytes = Data(repeating: 0xCD, count: 4096)
            let url = try tempFile(containing: bytes)
            defer { try? FileManager.default.removeItem(at: url) }

            // Cap below the actual file size so the streaming guard fires
            // mid-hash. Stops a runaway download from quietly turning into
            // a multi-GB hash job.
            do {
                try SandboxManager.verifySHA256(
                    of: url,
                    expected: sha256Hex(of: bytes),
                    maxBytes: 1024
                )
                Issue.record("Expected verifySHA256 to throw on oversized artifact")
            } catch let SandboxError.integrityCheckFailed(reason) {
                #expect(reason.contains("size cap"))
            } catch {
                Issue.record("Expected SandboxError.integrityCheckFailed, got \(error)")
            }
        }

        @Test
        func digestComparison_isCaseInsensitive() throws {
            let bytes = Data("hello-osaurus".utf8)
            let url = try tempFile(containing: bytes)
            defer { try? FileManager.default.removeItem(at: url) }

            // Maintainers might paste an upper-case digest from a release
            // page; the verifier normalizes both sides.
            try SandboxManager.verifySHA256(
                of: url,
                expected: sha256Hex(of: bytes).uppercased(),
                maxBytes: 1 << 20
            )
        }

        @Test
        func emptyFile_hashesToWellKnownDigest() throws {
            let url = try tempFile(containing: Data())
            defer { try? FileManager.default.removeItem(at: url) }

            // Empty SHA-256 is a famous constant — handy sanity check that
            // chunked-read handles 0-byte files without throwing.
            try SandboxManager.verifySHA256(
                of: url,
                expected: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                maxBytes: 1 << 20
            )
        }
    }

#endif
