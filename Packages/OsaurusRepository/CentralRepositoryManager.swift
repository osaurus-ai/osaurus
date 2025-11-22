//
//  CentralRepositoryManager.swift
//  osaurus
//
//  Manages the central plugin repository, including cloning, refreshing, and querying plugin specifications.
//

import Foundation

public struct CentralRepository {
    public let url: String
    public let branch: String?
    public init(url: String, branch: String? = nil) {
        self.url = url
        self.branch = branch
    }
}

public final class CentralRepositoryManager: @unchecked Sendable {
    public static let shared = CentralRepositoryManager()
    private init() {}

    public var central: CentralRepository = .init(
        url: "https://github.com/dinoki-ai/osaurus-tools.git",
        branch: nil
    )

    private func tapCloneDirectory() -> URL {
        ToolsPaths.pluginSpecsRoot().appendingPathComponent("central", isDirectory: true)
    }

    public func refresh() {
        let fm = FileManager.default
        let root = ToolsPaths.pluginSpecsRoot()
        if !fm.fileExists(atPath: root.path) {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let cloneDir = tapCloneDirectory()
        if fm.fileExists(atPath: cloneDir.appendingPathComponent(".git").path) {
            _ = runGit(in: cloneDir, args: ["fetch", "--all", "--tags"])
            _ = runGit(in: cloneDir, args: ["pull", "--ff-only", "origin"])
            if let branch = central.branch {
                _ = runGit(in: cloneDir, args: ["checkout", branch])
            }
        } else {
            var args = ["clone", "--depth", "1", central.url, cloneDir.path]
            if let branch = central.branch {
                args = ["clone", "--depth", "1", "--branch", branch, central.url, cloneDir.path]
            }
            _ = runGit(in: root, args: args)
        }
    }

    private func runGit(in directory: URL, args: [String]) -> (Int32, String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["git"] + args
        task.currentDirectoryURL = directory
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let s = String(data: data, encoding: .utf8) ?? ""
            return (task.terminationStatus, s)
        } catch {
            return (-1, "\(error)")
        }
    }

    public func listAllSpecs() -> [PluginSpec] {
        let fm = FileManager.default
        var specs: [PluginSpec] = []
        let base = tapCloneDirectory().appendingPathComponent("plugins", isDirectory: true)
        guard
            let enumr = fm.enumerator(
                at: base,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return specs
        }
        for case let fileURL as URL in enumr {
            if fileURL.pathExtension.lowercased() == "json" {
                if let data = try? Data(contentsOf: fileURL),
                    let spec = try? JSONDecoder().decode(PluginSpec.self, from: data)
                {
                    specs.append(spec)
                }
            }
        }
        return specs
    }

    public func spec(for pluginId: String) -> PluginSpec? {
        return listAllSpecs().first(where: { $0.plugin_id == pluginId })
    }
}
