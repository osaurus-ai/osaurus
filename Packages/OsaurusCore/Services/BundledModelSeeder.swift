//
//  BundledModelSeeder.swift
//  osaurus
//
//  First-launch installer for models shipped inside the app bundle.
//
//  The "full" distribution DMG bakes `OsaurusAI/Raptor-0.6-4B-JANG_6M` into
//  `Osaurus.app/Contents/Resources/BundledModels/` (staged by
//  `scripts/build/build_full_app.sh`, described by `manifest.json`). The
//  model is *seeded* into the user's models directory rather than loaded in
//  place: Sparkle updates replace the whole `.app` with the light build, so
//  a model that only existed inside the bundle would vanish on the first
//  update. Seeding once turns the full download into a first-run
//  accelerator and every later update stays small.
//
//  `FileManager.copyItem` clones on APFS when `/Applications` and the models
//  directory share a volume, so the seed is instant and costs no extra disk
//  until the bundled copy is replaced. A cross-volume models directory
//  (external drive) gets a real copy, verified by SHA-256.
//
//  Every failure degrades to the ordinary download path. Seeding never
//  blocks launch and never touches a directory that already exists.
//

import CryptoKit
import Foundation
import os

public enum BundledModelSeeder {
    // MARK: - Layout

    /// Subdirectory under the app bundle's Resources where the release
    /// pipeline stages bundled models plus the manifest.
    public static let bundleSubdirectory = "BundledModels"
    public static let manifestFilename = "manifest.json"

    /// Overrides the bundle lookup for local testing of the full-build path
    /// (point it at a directory containing `manifest.json` + `<org>/<repo>/`).
    static let environmentOverrideKey = "OSAURUS_BUNDLED_MODELS_DIR"

    /// Marker under `OsaurusPaths.root()` recording which `<id>@<revision>`
    /// pairs have already been seeded. A user who deletes the seeded model
    /// from the Models tab must not get it re-seeded on the next launch.
    static let seededMarkerFilename = "bundled-models-seeded.json"

    /// `userInfo` tag on the `.localModelsChanged` post so observers (and
    /// tests) can tell a seed apart from download/delete posts.
    static let notificationSourceKey = "source"
    static let notificationSourceValue = "BundledModelSeeder"

    private static let log = Logger(subsystem: "com.dinoki.osaurus", category: "BundledModelSeeder")

    // MARK: - Manifest

    struct Manifest: Decodable, Equatable, Sendable {
        struct File: Decodable, Equatable, Sendable {
            let path: String
            let bytes: Int64
            let sha256: String?
        }

        struct Model: Decodable, Equatable, Sendable {
            let id: String
            let revision: String
            let files: [File]

            var markerKey: String { "\(id)@\(revision)" }
        }

        let models: [Model]
    }

    enum Outcome: Equatable, Sendable {
        /// Copied into the models directory on this launch.
        case seeded(id: String)
        /// A complete bundle with this id was already on disk.
        case alreadyInstalled(id: String)
        /// Seeded on an earlier launch and since removed by the user.
        case previouslySeeded(id: String)
        case failed(id: String, reason: String)

        var id: String {
            switch self {
            case .seeded(let id), .alreadyInstalled(let id), .previouslySeeded(let id), .failed(let id, _):
                return id
            }
        }
    }

    // MARK: - Bundle resolution

    /// Locate the bundled-models root inside the signed app, if present.
    /// Returns `nil` for the light distribution and for SwiftPM/dev builds.
    public nonisolated static func bundledRoot(bundle: Bundle = .main) -> URL? {
        if let override = ProcessEnvironment.value(environmentOverrideKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            return FileManager.default.fileExists(atPath: url.appendingPathComponent(manifestFilename).path)
                ? url : nil
        }
        guard
            let root = bundle.resourceURL?
                .appendingPathComponent(bundleSubdirectory, isDirectory: true)
        else { return nil }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(manifestFilename).path)
            ? root : nil
    }

    /// Test seam: force the distribution verdict without a real bundle.
    nonisolated(unsafe) static var isFullDistributionOverrideForTests: Bool?

    private static let distributionLock = NSLock()
    private nonisolated(unsafe) static var cachedIsFullDistribution: Bool?

    /// `true` when this app was installed from the full DMG (a bundled
    /// models manifest ships inside the app). Drives the onboarding variant
    /// and the `distribution` telemetry dimension. Memoized: the answer is a
    /// property of the installed bundle and cannot change while running.
    public nonisolated static var isFullDistribution: Bool {
        if let override = isFullDistributionOverrideForTests { return override }
        distributionLock.lock()
        defer { distributionLock.unlock() }
        if let cached = cachedIsFullDistribution { return cached }
        let value = bundledRoot() != nil
        cachedIsFullDistribution = value
        return value
    }

    static func loadManifest(at root: URL) -> Manifest? {
        let url = root.appendingPathComponent(manifestFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard !manifest.models.isEmpty,
                manifest.models.allSatisfy({ isValidModelId($0.id) && !$0.files.isEmpty })
            else {
                log.error("Bundled models manifest at \(url.path, privacy: .public) has no usable entries")
                return nil
            }
            return manifest
        } catch {
            log.error(
                "Bundled models manifest at \(url.path, privacy: .public) is malformed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Ids are `<org>/<repo>`; reject anything that could escape the models
    /// directory when reduced into a path.
    static func isValidModelId(_ id: String) -> Bool {
        let parts = id.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && !part.hasPrefix(".")
        }
    }

    static func defaultMarkerURL() -> URL {
        OsaurusPaths.root().appendingPathComponent(seededMarkerFilename)
    }

    // MARK: - Seeding

    /// Seed every bundled model that is not already installed. Safe to call on
    /// every launch: the light build returns `[]` immediately.
    ///
    /// - Parameters:
    ///   - bundledRoot: Directory containing `manifest.json`; `nil` means no
    ///     bundled models (light build).
    ///   - modelsDirectory: The user's models root (`~/MLXModels` by default).
    ///   - markerURL: Where the seeded-marker JSON lives.
    ///   - notify: Post `.localModelsChanged` (and drop the discovery cache)
    ///     after at least one model was seeded.
    @discardableResult
    nonisolated static func seedIfNeeded(
        bundledRoot: URL? = bundledRoot(),
        modelsDirectory: URL = DirectoryPickerService.effectiveModelsDirectory(),
        markerURL: URL = defaultMarkerURL(),
        notify: Bool = true
    ) -> [Outcome] {
        guard let bundledRoot, let manifest = loadManifest(at: bundledRoot) else { return [] }

        var markers = readMarkers(at: markerURL)
        var outcomes: [Outcome] = []
        var seededAny = false

        for model in manifest.models {
            let outcome = seed(
                model,
                from: bundledRoot,
                into: modelsDirectory,
                alreadyMarked: markers[model.markerKey] != nil
            )
            outcomes.append(outcome)
            switch outcome {
            case .seeded:
                markers[model.markerKey] = ISO8601DateFormatter().string(from: Date())
                seededAny = true
                log.info(
                    "Seeded bundled model \(model.id, privacy: .public) into \(modelsDirectory.path, privacy: .public)"
                )
            case .alreadyInstalled:
                // Record it so a later user deletion is honored even though
                // this launch did not copy anything.
                if markers[model.markerKey] == nil {
                    markers[model.markerKey] = ISO8601DateFormatter().string(from: Date())
                }
            case .previouslySeeded:
                break
            case .failed(_, let reason):
                log.error("Bundled model \(model.id, privacy: .public) not seeded: \(reason, privacy: .public)")
            }
        }

        writeMarkers(markers, at: markerURL)

        if seededAny && notify {
            ModelManager.invalidateLocalModelsCache()
            NotificationCenter.default.post(
                name: .localModelsChanged,
                object: nil,
                userInfo: [notificationSourceKey: notificationSourceValue]
            )
        }
        return outcomes
    }

    private nonisolated static func seed(
        _ model: Manifest.Model,
        from bundledRoot: URL,
        into modelsDirectory: URL,
        alreadyMarked: Bool
    ) -> Outcome {
        let fm = FileManager.default
        let components = model.id.split(separator: "/").map(String.init)
        let source = components.reduce(bundledRoot) { $0.appendingPathComponent($1, isDirectory: true) }
        let destination = components.reduce(modelsDirectory) { $0.appendingPathComponent($1, isDirectory: true) }

        let probe = MLXModel(
            id: model.id,
            name: model.id,
            description: "",
            downloadURL: "",
            rootDirectory: modelsDirectory
        )
        if probe.computeIsDownloadedFromDisk() {
            return .alreadyInstalled(id: model.id)
        }
        if alreadyMarked {
            return .previouslySeeded(id: model.id)
        }
        if fm.fileExists(atPath: destination.path) {
            // Partial download or foreign directory — never overwrite.
            return .failed(id: model.id, reason: "destination exists but is not a complete bundle")
        }
        guard fm.fileExists(atPath: source.path) else {
            return .failed(id: model.id, reason: "bundled directory missing at \(source.path)")
        }

        let parent = destination.deletingLastPathComponent()
        let repoName = destination.lastPathComponent
        let stagingPrefix = ".\(repoName).seeding-"
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            return .failed(id: model.id, reason: "cannot create \(parent.path): \(error.localizedDescription)")
        }
        removeStaleStaging(in: parent, prefix: stagingPrefix)

        let staging = parent.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        do {
            try fm.copyItem(at: source, to: staging)
        } catch {
            return .failed(id: model.id, reason: "copy failed: \(error.localizedDescription)")
        }

        let verifyDigests = !sameVolume(source, staging)
        for file in model.files {
            let copied = staging.appendingPathComponent(file.path)
            guard let attributes = try? fm.attributesOfItem(atPath: copied.path),
                let size = attributes[.size] as? Int64
            else {
                return .failed(id: model.id, reason: "\(file.path) missing after copy")
            }
            guard size == file.bytes else {
                return .failed(id: model.id, reason: "\(file.path) is \(size) bytes, expected \(file.bytes)")
            }
            if verifyDigests, let expected = file.sha256?.lowercased(), !expected.isEmpty {
                guard let actual = sha256Hex(of: copied), actual == expected else {
                    return .failed(id: model.id, reason: "\(file.path) failed SHA-256 verification")
                }
            }
        }

        do {
            try fm.moveItem(at: staging, to: destination)
        } catch {
            return .failed(id: model.id, reason: "move into place failed: \(error.localizedDescription)")
        }
        return .seeded(id: model.id)
    }

    // MARK: - Helpers

    private nonisolated static func removeStaleStaging(in parent: URL, prefix: String) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: parent.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            try? fm.removeItem(at: parent.appendingPathComponent(name))
        }
    }

    private nonisolated static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard
            let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
            let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        else { return false }
        return va.isEqual(vb)
    }

    nonisolated static func sha256Hex(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func readMarkers(at url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private nonisolated static func writeMarkers(_ markers: [String: String], at url: URL) {
        guard !markers.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(markers).write(to: url, options: .atomic)
        } catch {
            log.error("Could not write bundled-model marker: \(error.localizedDescription, privacy: .public)")
        }
    }
}
