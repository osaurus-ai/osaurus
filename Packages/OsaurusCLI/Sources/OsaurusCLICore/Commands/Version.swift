//
//  Version.swift
//  osaurus
//
//  Command to display release metadata from the build environment or the
//  companion application bundle.
//

import Foundation

public struct VersionCommand: Command {
    public static let name = "version"

    public static func execute(args: [String]) async {
        print(output())
        exit(EXIT_SUCCESS)
    }

    public static func output(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executablePath: String = CommandLine.arguments.first ?? ""
    ) -> String {
        let resolved = CLIVersionResolver.resolve(
            environment: environment,
            executablePath: executablePath
        )
        if let version = resolved.version, let build = resolved.build {
            return "Osaurus \(version) (\(build))"
        }
        if let version = resolved.version { return "Osaurus \(version)" }
        return "Osaurus dev"
    }
}
