//
//  MLXMetallibBootstrap.swift
//  OsaurusEvalsKit
//
//  Runtime belt-and-suspenders for the SwiftPM eval CLI: colocate MLX's
//  `default.metallib` next to the running `osaurus-evals` binary so a
//  local MLX model load doesn't fail with "Failed to load the default
//  metallib". SwiftPM CLI builds (unlike `make app`, which embeds the
//  `mlx-swift_Cmlx.bundle`) don't ship the Metal shader library beside
//  the executable. `scripts/evals/prepare-evals-env.sh` does this ahead
//  of time for `make evals`; this is the fallback for direct binary runs.
//  Both no-op when the metallib is already present.
//

import Foundation
import os

public enum MLXMetallibBootstrap {
    private static let logger = Logger(subsystem: "ai.osaurus", category: "MLXMetallibBootstrap")

    /// Copies a discovered `default.metallib` next to the running binary
    /// (as both `default.metallib` and `mlx.metallib`) if it isn't already
    /// there. Cheap and idempotent — a no-op when colocated or when no
    /// source metallib can be found on this host.
    public static func ensureBesideExecutable() {
        let fm = FileManager.default
        let destinations = destinationDirectories()
        guard !destinations.isEmpty else { return }

        let alreadyColocated = destinations.contains { dir in
            fm.fileExists(atPath: dir.appendingPathComponent("default.metallib").path)
                || fm.fileExists(atPath: dir.appendingPathComponent("mlx.metallib").path)
        }
        if alreadyColocated { return }

        guard let source = locateSource(fileManager: fm, destinations: destinations) else {
            logger.notice(
                "No source default.metallib found; local MLX model loads may fail. Run `make evals-prep`, build the app once with `make app`, or set OSAURUS_MLX_METALLIB."
            )
            return
        }

        for dir in destinations {
            for name in ["default.metallib", "mlx.metallib"] {
                let dest = dir.appendingPathComponent(name)
                guard !fm.fileExists(atPath: dest.path) else { continue }
                do {
                    try fm.copyItem(at: source, to: dest)
                    logger.info("Colocated MLX metallib at \(dest.path, privacy: .public)")
                } catch {
                    logger.error(
                        "Failed to colocate MLX metallib at \(dest.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    private static func destinationDirectories() -> [URL] {
        var dirs: [URL] = []
        if let exe = Bundle.main.executableURL {
            dirs.append(exe.deletingLastPathComponent())
        }
        if let first = CommandLine.arguments.first, !first.isEmpty {
            dirs.append(URL(fileURLWithPath: first).deletingLastPathComponent())
        }
        var seen: Set<String> = []
        return dirs.compactMap { url in
            let standardized = url.standardizedFileURL
            return seen.insert(standardized.path).inserted ? standardized : nil
        }
    }

    private static func locateSource(fileManager fm: FileManager, destinations: [URL]) -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let path = env["OSAURUS_MLX_METALLIB"], !path.isEmpty, fm.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        // An existing colocated copy in any destination dir is a valid source.
        for dir in destinations {
            for name in ["default.metallib", "mlx.metallib"] {
                let candidate = dir.appendingPathComponent(name)
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }

        // Xcode DerivedData build products (`make app` / xcodebuild). The
        // DerivedData hash is machine-specific, so enumerate `osaurus-*`.
        let derived = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/DerivedData")
        let relativeCandidates = [
            "Build/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib",
            "Build/Products/Release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib",
            "Build/Products/Debug/osaurus.app/Contents/Resources/default.metallib",
        ]
        if let entries = try? fm.contentsOfDirectory(
            at: derived,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries where entry.lastPathComponent.hasPrefix("osaurus-") {
                for relative in relativeCandidates {
                    let candidate = entry.appendingPathComponent(relative)
                    if fm.fileExists(atPath: candidate.path) { return candidate }
                }
            }
        }

        return nil
    }
}
