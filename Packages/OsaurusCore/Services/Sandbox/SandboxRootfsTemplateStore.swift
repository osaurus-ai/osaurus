//
//  SandboxRootfsTemplateStore.swift
//  osaurus
//
//  Immutable base-template + copy-on-write clone management for the
//  sandbox root filesystem.
//
//  The first cold boot unpacks the pinned OCI image into an 8 GiB
//  `rootfs.ext4` (tens of seconds). This store captures that pristine,
//  never-booted filesystem as an immutable template keyed by
//  (image digest, runtime format version) using APFS `clonefile` — an
//  O(1) metadata operation that shares every block with the source.
//  From then on:
//
//  - Any boot that would have re-unpacked (reset, invalidated warm
//    stamp, warm-boot corruption fallback) clones the template in
//    milliseconds instead.
//  - With per-agent environments enabled, each agent gets its own
//    clone under `container/environments/<agent>/`, so system-level
//    package state (apk) persists per agent instead of in one shared
//    mutable rootfs. Environments are bounded: least-recently-used
//    clones beyond the cap are evicted (they re-clone from the
//    template on next use; the agent's home stays on the virtiofs
//    workspace and is never touched by eviction).
//
//  Templates are never booted and never mutated after capture. A key
//  change (image bump or runtime-format change) makes old templates and
//  environments unreachable; `pruneTemplates` / stale-environment
//  eviction reclaim the space. Thanks to CoW, a template plus N fresh
//  clones occupy roughly one rootfs of physical disk until clones
//  diverge.
//

import CryptoKit
import Foundation

#if os(macOS)

    public enum SandboxRootfsTemplateStore {

        // MARK: - Keys and paths

        /// Filesystem-safe cache key binding a template to the exact image
        /// digest and runtime format that produced it. Mirrors the warm-boot
        /// stamp pair in `SandboxManager.warmBootStampValid`.
        public static func templateKey(
            imageReference: String,
            runtimeFormatVersion: String
        ) -> String {
            let digest = SHA256.hash(data: Data("\(imageReference)|\(runtimeFormatVersion)".utf8))
            return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        }

        static func templatesDir() -> URL {
            OsaurusPaths.container().appendingPathComponent("templates", isDirectory: true)
        }

        static func environmentsDir() -> URL {
            OsaurusPaths.container().appendingPathComponent("environments", isDirectory: true)
        }

        static func templateFile(key: String) -> URL {
            templatesDir().appendingPathComponent("rootfs-\(key).ext4")
        }

        public static func environmentDir(agentName: String) -> URL {
            environmentsDir().appendingPathComponent(safeName(agentName), isDirectory: true)
        }

        public static func environmentRootfs(agentName: String) -> URL {
            environmentDir(agentName: agentName).appendingPathComponent("rootfs.ext4")
        }

        static func environmentStampFile(agentName: String) -> URL {
            environmentDir(agentName: agentName).appendingPathComponent("stamp.json")
        }

        /// Environment directory names come from the agent's Linux user name
        /// (already `[a-z0-9-]`), but sanitize defensively — a path traversal
        /// here would delete outside the environments dir on eviction.
        static func safeName(_ name: String) -> String {
            let cleaned = name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }
            return cleaned.isEmpty ? "agent" : String(cleaned.prefix(64))
        }

        // MARK: - Template lifecycle

        public static func hasTemplate(key: String) -> Bool {
            FileManager.default.fileExists(atPath: templateFile(key: key).path)
        }

        /// Capture `rootfs` (a pristine, never-booted unpack) as the immutable
        /// template for `key`. No-op when the template already exists. Also
        /// prunes templates for other keys — only the current pin is ever
        /// reachable, so keeping old ones would just leak disk.
        public static func captureTemplate(from rootfs: URL, key: String) throws {
            let target = templateFile(key: key)
            if FileManager.default.fileExists(atPath: target.path) {
                pruneTemplates(keeping: key)
                return
            }
            try OsaurusPaths.ensureExists(templatesDir())
            try cowClone(from: rootfs, to: target)
            pruneTemplates(keeping: key)
        }

        /// Drop the template for `key` (e.g. after a boot from it failed —
        /// the next full unpack recaptures a fresh one).
        public static func invalidateTemplate(key: String) {
            try? FileManager.default.removeItem(at: templateFile(key: key))
        }

        /// Remove every template except `key`'s.
        public static func pruneTemplates(keeping key: String) {
            let fm = FileManager.default
            let keep = templateFile(key: key).lastPathComponent
            guard
                let entries = try? fm.contentsOfDirectory(
                    at: templatesDir(), includingPropertiesForKeys: nil
                )
            else { return }
            for entry in entries where entry.lastPathComponent != keep {
                try? fm.removeItem(at: entry)
            }
        }

        /// Clone the template for `key` to `destination` (replacing any
        /// existing file). CoW when the volume supports it, so this is
        /// milliseconds instead of an 8 GiB copy.
        public static func cloneTemplate(key: String, to destination: URL) throws {
            let source = templateFile(key: key)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw SandboxError.provisionFailed("No rootfs template for key \(key)")
            }
            try OsaurusPaths.ensureExists(destination.deletingLastPathComponent())
            try cowClone(from: source, to: destination)
        }

        /// `clonefile(2)`-based copy with a plain-copy fallback for volumes
        /// that don't support CoW clones. The destination is replaced.
        static func cowClone(from source: URL, to destination: URL) throws {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            if clonefile(source.path, destination.path, 0) == 0 {
                return
            }
            try fm.copyItem(at: source, to: destination)
        }

        // MARK: - Per-agent environments

        /// Per-environment provenance + recency stamp.
        public struct EnvironmentStamp: Codable, Sendable, Equatable {
            /// Template key the clone was made from. A mismatch means the
            /// image/runtime pin moved and the clone is stale.
            public var key: String
            public var lastUsedAt: Date

            public init(key: String, lastUsedAt: Date = Date()) {
                self.key = key
                self.lastUsedAt = lastUsedAt
            }
        }

        static func loadStamp(agentName: String) -> EnvironmentStamp? {
            guard let data = try? Data(contentsOf: environmentStampFile(agentName: agentName))
            else { return nil }
            return try? JSONDecoder().decode(EnvironmentStamp.self, from: data)
        }

        static func saveStamp(_ stamp: EnvironmentStamp, agentName: String) {
            guard let data = try? JSONEncoder().encode(stamp) else { return }
            try? data.write(to: environmentStampFile(agentName: agentName), options: .atomic)
        }

        /// True when the agent's clone exists and was made from the current
        /// template key — i.e. it can boot without re-cloning.
        public static func environmentIsValid(agentName: String, key: String) -> Bool {
            FileManager.default.fileExists(atPath: environmentRootfs(agentName: agentName).path)
                && loadStamp(agentName: agentName)?.key == key
        }

        /// Ensure the agent has a valid clone for `key`, creating or
        /// re-cloning as needed, and touch its recency stamp. Returns the
        /// rootfs path to boot from.
        @discardableResult
        public static func ensureEnvironment(agentName: String, key: String) throws -> URL {
            let rootfs = environmentRootfs(agentName: agentName)
            if !environmentIsValid(agentName: agentName, key: key) {
                try OsaurusPaths.ensureExists(environmentDir(agentName: agentName))
                try cloneTemplate(key: key, to: rootfs)
            }
            saveStamp(EnvironmentStamp(key: key), agentName: agentName)
            return rootfs
        }

        /// Refresh the recency stamp without touching the clone.
        public static func touchEnvironment(agentName: String) {
            guard var stamp = loadStamp(agentName: agentName) else { return }
            stamp.lastUsedAt = Date()
            saveStamp(stamp, agentName: agentName)
        }

        /// Discard the agent's clone entirely. The next use re-clones a
        /// fresh environment from the template; the agent's home directory
        /// lives on the virtiofs workspace and is unaffected.
        public static func resetEnvironment(agentName: String) throws {
            let dir = environmentDir(agentName: agentName)
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
        }

        /// All known environments with their stamps, least recently used
        /// first. Unstamped directories sort oldest so they're evicted first.
        public static func listEnvironments() -> [(name: String, stamp: EnvironmentStamp?)] {
            let fm = FileManager.default
            guard
                let entries = try? fm.contentsOfDirectory(
                    at: environmentsDir(), includingPropertiesForKeys: [.isDirectoryKey]
                )
            else { return [] }
            return
                entries
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map { (name: $0.lastPathComponent, stamp: loadStamp(agentName: $0.lastPathComponent)) }
                .sorted { ($0.stamp?.lastUsedAt ?? .distantPast) < ($1.stamp?.lastUsedAt ?? .distantPast) }
        }

        /// Bound the environment pool: evict least-recently-used clones
        /// beyond `max`, plus any clone made from a different template key
        /// (unreachable — the pin moved). `protecting` (the currently booted
        /// environment) is never evicted. Returns the evicted names.
        @discardableResult
        public static func enforceLimit(
            max: Int,
            currentKey: String,
            protecting protected: String? = nil
        ) -> [String] {
            var evicted: [String] = []
            var live: [(name: String, stamp: EnvironmentStamp?)] = []
            for env in listEnvironments() {
                if env.name != protected, env.stamp?.key != currentKey {
                    try? resetEnvironment(agentName: env.name)
                    evicted.append(env.name)
                } else {
                    live.append(env)
                }
            }
            var overflow = live.count - Swift.max(max, 1)
            guard overflow > 0 else { return evicted }
            for env in live {  // already LRU-first
                guard overflow > 0 else { break }
                guard env.name != protected else { continue }
                try? resetEnvironment(agentName: env.name)
                evicted.append(env.name)
                overflow -= 1
            }
            return evicted
        }

        // MARK: - Diagnostics

        /// Total on-disk bytes attributed to templates and environments.
        /// Note: CoW clones report full logical size; physical usage is
        /// far lower until clones diverge.
        public static func logicalBytes() -> Int {
            OsaurusPaths.directorySize(at: templatesDir())
                + OsaurusPaths.directorySize(at: environmentsDir())
        }

        /// Remove everything — templates and all environments. Used by
        /// container removal so "Remove" really reclaims the disk.
        public static func removeAll() {
            try? FileManager.default.removeItem(at: templatesDir())
            try? FileManager.default.removeItem(at: environmentsDir())
        }
    }

#endif
