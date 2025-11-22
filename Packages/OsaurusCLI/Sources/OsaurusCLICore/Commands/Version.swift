//
//  Version.swift
//  osaurus
//
//  Command to display the Osaurus version and build number from environment variables.
//

import Foundation

public struct VersionCommand: Command {
    public static let name = "version"

    public static func execute(args: [String]) async {
        var versionString: String?
        var buildString: String?

        if let v = ProcessInfo.processInfo.environment["OSAURUS_VERSION"] { versionString = v }
        if let b = ProcessInfo.processInfo.environment["OSAURUS_BUILD_NUMBER"] { buildString = b }

        let output: String
        if let v = versionString, let b = buildString, !b.isEmpty {
            output = "Osaurus \(v) (\(b))"
        } else if let v = versionString {
            output = "Osaurus \(v)"
        } else {
            output = "Osaurus dev"
        }
        print(output)
        exit(EXIT_SUCCESS)
    }
}
