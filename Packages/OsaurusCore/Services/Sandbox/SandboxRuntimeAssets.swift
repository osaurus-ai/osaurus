//
//  SandboxRuntimeAssets.swift
//  osaurus
//
//  Single source of truth for the identity of every runtime asset the
//  sandbox boots from: the pinned Linux kernel, the vminit OCI initfs
//  reference, and the runtime format version that keys the warm-boot
//  cache. Everything here is digest-pinned — a mirror or registry
//  compromise cannot swap the bytes the VM boots without failing
//  verification on the host.
//

import Foundation

#if os(macOS)

    public enum SandboxRuntimeAssets {
        // MARK: - Kernel

        /// Version of the Kata-built guest kernel (`vmlinux-<version>`).
        /// The full Kata distribution tarball is 277 MiB, of which only
        /// this ~14 MiB kernel is retained, so release builds bundle the
        /// extracted binary in the signed app (see
        /// `scripts/build/fetch_sandbox_kernel.sh`) and the tarball
        /// download is only a fallback for dev builds / stripped bundles.
        public static let kernelVersion = "6.12.28-153"

        /// Upstream Kata Containers release the kernel is extracted from.
        /// Kept for provenance: the kernel is GPL-2.0 and the source offer
        /// points at this release tag.
        public static let kernelUpstreamRelease = "kata-containers 3.17.0"

        /// SHA-256 of the extracted `vmlinux` binary itself. Both the
        /// bundled copy and the tarball-extracted copy must match this
        /// digest before the file is installed — fail-closed.
        public static let kernelSHA256 =
            "67bac9f416af4cdc9b151e4ba4962d6515e0ad7acc53816761cf964aa6af6ea0"

        /// Fallback source: the full Kata static tarball, verified by its
        /// own digest before extraction. Update all four kernel constants
        /// together when rotating the kernel.
        public static let kernelTarballURL =
            "https://github.com/kata-containers/kata-containers/releases/download/3.17.0/kata-static-3.17.0-arm64.tar.xz"
        public static let kernelTarballSHA256 =
            "647c7612e6edf789d5e14698c48c99d8bac15ad139ffaa1c8bb7d229f748d181"

        // MARK: - InitFS (vminit OCI artifact)

        /// Apple's digest-pinned `vminit` OCI artifact for the
        /// Containerization release we link against. ~64 MiB compressed
        /// (versus the 256 MiB raw ext4 blob it replaces) and pulled with
        /// the SDK's concurrent layer downloader. The digest is the
        /// multi-arch index digest of `vminit:0.35.0`; rotate it together
        /// with the `containerization` pin in Package.swift.
        public static let initfsReference =
            "ghcr.io/apple/containerization/vminit@sha256:5708d65ba1914caa756a2e813831e17d7655042799310bc94efef82210c2dac6"

        // MARK: - Runtime format version

        /// Compatibility stamp for the (Containerization SDK, initfs)
        /// pair persisted in `SandboxConfiguration.lastRuntimeFormatVersion`.
        /// When the stamp on disk doesn't match, the cached initfs is
        /// rebuilt and the warm rootfs path is skipped once, so a rootfs
        /// produced under an older runtime can never enter a failed warm
        /// boot before rebuilding. Bump whenever the SDK pin or the
        /// initfs delivery format changes incompatibly.
        public static let runtimeFormatVersion = "cz-0.35/vminit-oci-1"

        // MARK: - Bundled kernel resolution

        /// Subdirectory under the app bundle's Resources where the release
        /// pipeline stages the extracted kernel plus its provenance sidecar.
        public static let bundleSubdirectory = "SandboxRuntime"

        /// Locate the kernel bundled in the signed app, if present.
        /// Returns `nil` for SwiftPM/dev builds (which fall back to the
        /// tarball download). `OSAURUS_SANDBOX_KERNEL_PATH` overrides the
        /// lookup for local testing of the bundled-install path.
        public static func bundledKernelURL() -> URL? {
            if let override = ProcessInfo.processInfo.environment["OSAURUS_SANDBOX_KERNEL_PATH"],
                !override.isEmpty
            {
                let url = URL(fileURLWithPath: override)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            guard
                let resources = Bundle.main.resourceURL?
                    .appendingPathComponent(bundleSubdirectory, isDirectory: true)
            else { return nil }
            let candidate = resources.appendingPathComponent("vmlinux")
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
    }

#endif
