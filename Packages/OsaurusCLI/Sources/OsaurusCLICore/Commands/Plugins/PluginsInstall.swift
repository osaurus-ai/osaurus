//
//  PluginsInstall.swift
//  osaurus
//
//  Command to install a plugin from configured taps with optional version specification.
//

import Foundation
import OsaurusRepository

public struct PluginsInstall {
    public static func execute(args: [String]) async {
        guard let pluginId = args.first, !pluginId.isEmpty else {
            fputs("Usage: osaurus plugins install <plugin_id> [--version <semver>]\n", stderr)
            exit(EXIT_FAILURE)
        }
        var preferredVersion: SemanticVersion? = nil
        if let idx = args.firstIndex(of: "--version"), idx + 1 < args.count {
            let vstr = args[idx + 1]
            preferredVersion = SemanticVersion.parse(vstr)
            if preferredVersion == nil {
                fputs("Invalid semver: \(vstr)\n", stderr)
                exit(EXIT_FAILURE)
            }
        }
        do {
            let result = try await PluginInstallManager.shared.install(
                pluginId: pluginId,
                preferredVersion: preferredVersion
            )
            print(
                "Installed \(result.receipt.plugin_id) @ \(result.receipt.version) to \(result.installDirectory.path)"
            )
            exit(EXIT_SUCCESS)
        } catch {
            fputs("Install failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
