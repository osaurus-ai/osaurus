//
//  Version.swift
//  osaurus
//
//  Command to display the Osaurus version and build number from the app bundle or Info.plist.
//

import Foundation

public struct VersionCommand: Command {
    public static let name = "version"

    public static func execute(args: [String]) async {
        let invokedPath = CommandLine.arguments.first ?? ""
        var versionString: String?
        var buildString: String?

        // Try: If running inside an app bundle (Contents/Helpers or Contents/MacOS)
        do {
            let execURL = URL(fileURLWithPath: invokedPath)
            let contentsURL = execURL.deletingLastPathComponent().deletingLastPathComponent()
            if contentsURL.lastPathComponent == "Contents" {
                let infoURL = contentsURL.appendingPathComponent("Info.plist")
                if FileManager.default.fileExists(atPath: infoURL.path) {
                    let data = try Data(contentsOf: infoURL)
                    var format = PropertyListSerialization.PropertyListFormat.xml
                    if let plist = try PropertyListSerialization.propertyList(
                        from: data,
                        options: [],
                        format: &format
                    ) as? [String: Any] {
                        if let v = plist["CFBundleShortVersionString"] as? String { versionString = v }
                        if let b = plist["CFBundleVersion"] as? String { buildString = b }
                    }
                }
            }
        } catch {
            // ignore
        }

        // Fallback to Bundle.main (may be empty for SPM executables)
        if versionString == nil {
            let info = Bundle.main.infoDictionary ?? [:]
            if let v = info["CFBundleShortVersionString"] as? String { versionString = v }
            if let b = info["CFBundleVersion"] as? String { buildString = b }
        }

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
