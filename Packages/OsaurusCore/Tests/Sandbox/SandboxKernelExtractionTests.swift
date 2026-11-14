//
//  SandboxKernelExtractionTests.swift
//  OsaurusCoreTests
//
//  The Kata kernel fallback ships as a `.tar.zst` whose entries carry a
//  `./` prefix. Stock macOS `/usr/bin/tar` cannot read zstd without an
//  external binary the app's PATH doesn't have, so extraction must work
//  in-process.
//

#if os(macOS)

    import Foundation
    import Testing

    @testable import OsaurusCore

    @Suite("Sandbox kernel extraction")
    struct SandboxKernelExtractionTests {

        /// `zstd -19` of a ustar archive with `./opt/kata/share/kata-containers/
        /// vmlinux-6.18.35-197` ("osaurus-test-kernel") and `./opt/kata/bin/other`.
        private static let kataLikeArchiveBase64 =
            "KLUv/WQAFZUGAHJKHxeQ6QFATHFZfKFFiLsr2JJKMiWNi5k+Lc2bM/c2ofHyJDBOiKSn8BOtsz4qF53e7V7t3pzAiS0gYKClpsYjURjvdopOGI/3URKJnV3B+Qy6TcVjWLvU+4egPUXxnh74lt898z2th6HjmJsXbWOLfblmjLy3Icbc7h71i1RAIiBwKyijOQu89w/q9YkCfVsB2QBU6m5mwJh0QOmC9FUGpnIyDkc4A6HULKFMWwGdSgSp8qbiQoq8qQNxVAccgiQK1l2MDYc/kPoBYjT3ZXTKRnSdQ5c="

        private func makeWorkDir() throws -> URL {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("kernel-extract-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }

        private func writeArchive(in dir: URL) throws -> URL {
            let url = dir.appendingPathComponent("kata.tar.zst")
            try #require(Data(base64Encoded: Self.kataLikeArchiveBase64)).write(to: url)
            return url
        }

        @Test
        func extractsPinnedKernelPathFromZstdTarball() throws {
            let dir = try makeWorkDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let archive = try writeArchive(in: dir)
            let destination = dir.appendingPathComponent("vmlinux")

            try SandboxManager.extractArchiveMember(
                SandboxRuntimeAssets.kernelArchivePath,
                from: archive,
                to: destination
            )

            let contents = try String(contentsOf: destination, encoding: .utf8)
            #expect(contents == "osaurus-test-kernel")
        }

        @Test
        func missingMemberThrowsAndWritesNothing() throws {
            let dir = try makeWorkDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let archive = try writeArchive(in: dir)
            let destination = dir.appendingPathComponent("vmlinux")

            #expect(throws: (any Error).self) {
                try SandboxManager.extractArchiveMember(
                    "opt/kata/share/kata-containers/vmlinux-0.0.0-missing",
                    from: archive,
                    to: destination
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

#endif
