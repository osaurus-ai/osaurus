//
//  AppIdentity.swift
//  OsaurusCLI
//
//  Which Osaurus app this CLI belongs to. The CLI ships inside the app
//  (`Osaurus.app/Contents/Helpers/osaurus`), so a CLI inside Osaurus Beta
//  must launch and talk to Osaurus Beta, not the stable app.
//

import Foundation

public enum AppIdentity {
    public static let defaultBundleIdentifier = "com.dinoki.osaurus"

    /// Bundle id of the companion app, from its `Info.plist`.
    /// `OSAURUS_APP_BUNDLE_ID` overrides it for proof builds.
    public static let bundleIdentifier: String = resolveBundleIdentifier()

    static func resolveBundleIdentifier(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executablePath: String = CommandLine.arguments.first ?? ""
    ) -> String {
        if let override = environment["OSAURUS_APP_BUNDLE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty
        {
            return override
        }
        guard let app = CLIVersionResolver.companionAppPath(for: executablePath),
            let id = bundleIdentifier(ofAppAt: app)
        else { return defaultBundleIdentifier }
        return id
    }

    static func bundleIdentifier(ofAppAt appPath: String) -> String? {
        let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = object as? [String: Any],
            let id = dictionary["CFBundleIdentifier"] as? String,
            !id.isEmpty
        else { return nil }
        return id
    }
}
