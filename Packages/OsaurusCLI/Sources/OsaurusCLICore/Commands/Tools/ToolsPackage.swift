//
//  ToolsPackage.swift
//  osaurus
//
//  Command to package a plugin by creating a zip file containing manifest.json and the dylib.
//

import Foundation

public struct ToolsPackage {
    public static func execute(args: [String]) {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let manifestURL = cwd.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            fputs("manifest.json not found in current directory\n", stderr)
            exit(EXIT_FAILURE)
        }
        // Read manifest to find dylib filename
        struct Manifest: Decodable { let name: String?; let id: String?; let dylib: String }
        let manifest: Manifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            fputs("Failed to parse manifest.json: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
        let dylibURL = cwd.appendingPathComponent(manifest.dylib)
        guard FileManager.default.fileExists(atPath: dylibURL.path) else {
            fputs(
                "Dylib \(manifest.dylib) not found. Build your plugin and place the dylib alongside manifest.json.\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }
        // Zip manifest.json and dylib into <id or name>.zip
        let zipName = (manifest.id ?? manifest.name ?? "plugin") + ".zip"
        let zipURL = cwd.appendingPathComponent(zipName)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.arguments = ["-q", "-r", zipURL.path, "manifest.json", manifest.dylib]
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
        exit(EXIT_SUCCESS)
    }
}
