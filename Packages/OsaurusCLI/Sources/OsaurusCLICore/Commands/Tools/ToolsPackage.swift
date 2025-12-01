//
//  ToolsPackage.swift
//  osaurus
//
//  Command to package a plugin by creating a zip file containing the dylib.
//  Output format: <plugin_id>-<version>.zip
//

import Foundation

public struct ToolsPackage {
    public static func execute(args: [String]) {
        // Parse arguments: osaurus tools package <plugin_id> <version> [dylib_path]
        guard args.count >= 2 else {
            fputs("Usage: osaurus tools package <plugin_id> <version> [dylib_path]\n", stderr)
            fputs("  If dylib_path is omitted, auto-detects .dylib files in current directory.\n", stderr)
            exit(EXIT_FAILURE)
        }

        let pluginId = args[0]
        let version = args[1]

        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)

        // Find dylib file(s) to include
        var dylibPaths: [String] = []

        if args.count >= 3 {
            // Use specified dylib path
            let dylibPath = args[2]
            guard fm.fileExists(atPath: cwd.appendingPathComponent(dylibPath).path) else {
                fputs("Dylib not found: \(dylibPath)\n", stderr)
                exit(EXIT_FAILURE)
            }
            dylibPaths.append(dylibPath)
        } else {
            // Auto-detect .dylib files in current directory
            do {
                let contents = try fm.contentsOfDirectory(atPath: cwd.path)
                dylibPaths = contents.filter { $0.hasSuffix(".dylib") }
            } catch {
                fputs("Failed to read current directory: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }

            guard !dylibPaths.isEmpty else {
                fputs("No .dylib files found in current directory.\n", stderr)
                fputs("Build your plugin first, or specify the dylib path explicitly.\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        // Create zip file with naming convention: <plugin_id>-<version>.zip
        let zipName = "\(pluginId)-\(version).zip"
        let zipURL = cwd.appendingPathComponent(zipName)

        // Remove existing zip if present
        if fm.fileExists(atPath: zipURL.path) {
            try? fm.removeItem(at: zipURL)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = cwd
        proc.arguments = ["-q", "-r", zipURL.path] + dylibPaths

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                fputs("zip command failed; ensure /usr/bin/zip is available.\n", stderr)
                exit(EXIT_FAILURE)
            }
        } catch {
            fputs("Failed to run zip: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }

        print("Created \(zipName)")
        print("Install with: osaurus tools install ./\(zipName)")
        exit(EXIT_SUCCESS)
    }
}
