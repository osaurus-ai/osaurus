//
//  ToolsPackage.swift
//  osaurus
//
//  Command to package a plugin by creating a zip file containing the dylib
//  and v2 companion files (web/, SKILL.md, README.md, CHANGELOG.md).
//  Output format: <plugin_id>-<version>.zip
//

import Foundation

public struct ToolsPackage {
    static let companionFiles = ["SKILL.md", "README.md", "CHANGELOG.md"]
    static let companionDirs = ["web"]

    static func findDylibs(in directory: URL) throws -> [String] {
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return contents.filter { $0.hasSuffix(".dylib") }
    }

    static func collectCompanionEntries(in directory: URL) -> [String] {
        let fm = FileManager.default
        var entries: [String] = []

        for file in companionFiles {
            if fm.fileExists(atPath: directory.appendingPathComponent(file).path) {
                entries.append(file)
            }
        }

        for dirName in companionDirs {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: directory.appendingPathComponent(dirName).path, isDirectory: &isDir),
                isDir.boolValue
            {
                entries.append(dirName)
            }
        }

        return entries
    }

    static func zipName(pluginId: String, version: String) -> String {
        "\(pluginId)-\(version).zip"
    }

    public static func execute(args: [String]) {
        guard args.count >= 2 else {
            fputs("Usage: osaurus tools package <plugin_id> <version> [dylib_path]\n", stderr)
            fputs("  If dylib_path is omitted, auto-detects .dylib files in current directory.\n", stderr)
            fputs("  Also includes web/, SKILL.md, README.md, CHANGELOG.md if present.\n", stderr)
            exit(EXIT_FAILURE)
        }

        let pluginId = args[0]
        let version = args[1]

        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)

        var dylibPaths: [String] = []

        if args.count >= 3 {
            let dylibPath = args[2]
            guard fm.fileExists(atPath: cwd.appendingPathComponent(dylibPath).path) else {
                fputs("Dylib not found: \(dylibPath)\n", stderr)
                exit(EXIT_FAILURE)
            }
            dylibPaths.append(dylibPath)
        } else {
            do {
                dylibPaths = try findDylibs(in: cwd)
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

        var zipEntries = dylibPaths
        zipEntries.append(contentsOf: collectCompanionEntries(in: cwd))

        let name = zipName(pluginId: pluginId, version: version)
        let zipURL = cwd.appendingPathComponent(name)

        if fm.fileExists(atPath: zipURL.path) {
            try? fm.removeItem(at: zipURL)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = cwd
        proc.arguments = ["-q", "-r", zipURL.path] + zipEntries

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

        let extras = zipEntries.filter { !$0.hasSuffix(".dylib") }
        if !extras.isEmpty {
            print("Created \(name) (includes: \(extras.joined(separator: ", ")))")
        } else {
            print("Created \(name)")
        }
        print("Install with: osaurus tools install ./\(name)")
        exit(EXIT_SUCCESS)
    }
}
