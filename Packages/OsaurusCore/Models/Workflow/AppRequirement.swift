//
//  AppRequirement.swift
//  osaurus
//
//  A Mac app a workflow's steps drive (Shortcuts, Xcode, Final Cut Pro)
//  through AppleScript, Computer Use, a Mac query, or a shell command.
//  Those steps name the app in prose, so the graph cannot say which app
//  it is: the Architect declares it (`declare_app`), the template carries
//  it, and setup checks the app is installed on each Mac before a run.
//  Only the bundle id, name, help, and where to get it travel.
//

import Foundation

public struct AppRequirement: Codable, Equatable, Sendable, Identifiable {
    /// The app's bundle identifier, e.g. `com.apple.shortcuts`.
    public var bundleID: String
    /// The name the person knows it by, e.g. "Shortcuts".
    public var name: String
    /// What the workflow uses it for.
    public var help: String?
    /// Where to get the app (an App Store or download page).
    public var url: String?
    /// The workflow still runs without it (a step that skips or fails
    /// softly), so setup only mentions it.
    public var optional: Bool

    public var id: String { bundleID.lowercased() }

    public init(bundleID: String, name: String, help: String? = nil, url: String? = nil, optional: Bool = false) {
        self.bundleID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.help = help
        self.url = url
        self.optional = optional
    }

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case name, help, url, optional
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let bundleID = try c.decode(String.self, forKey: .bundleID)
        self.init(
            bundleID: bundleID,
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? bundleID,
            help: try c.decodeIfPresent(String.self, forKey: .help),
            url: try c.decodeIfPresent(String.self, forKey: .url),
            optional: try c.decodeIfPresent(Bool.self, forKey: .optional) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(bundleID, forKey: .bundleID)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(help, forKey: .help)
        try c.encodeIfPresent(url, forKey: .url)
        if optional { try c.encode(true, forKey: .optional) }
    }

    /// The download page when it is an https or App Store URL.
    public var downloadURL: URL? {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines), let parsed = URL(string: raw),
            let scheme = parsed.scheme?.lowercased(), scheme == "https" || scheme == "macappstore"
        else { return nil }
        return parsed
    }

    /// Validation problems a definition or draft op must not carry.
    public var issues: [String] {
        var out: [String] = []
        if !Self.isValidBundleID(bundleID) {
            out.append(
                "app `\(bundleID)`: the bundle id must be reverse-DNS, like `com.apple.shortcuts`; look it up with `workflow_discover` action `apps`"
            )
        }
        if name.isEmpty {
            out.append("app `\(bundleID)`: give it the name the person knows it by, like \"Shortcuts\"")
        }
        if let url, !url.trimmingCharacters(in: .whitespaces).isEmpty, downloadURL == nil {
            out.append("app `\(bundleID)`: `url` must be an https or macappstore link")
        }
        return out
    }

    /// Two or more dot-separated parts of letters, digits, `-` and `_`.
    public static func isValidBundleID(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
        }
    }

    /// Upsert by bundle id, keeping the declared order.
    public static func upserting(_ app: AppRequirement, in list: [AppRequirement]) -> [AppRequirement] {
        var out = list
        if let index = out.firstIndex(where: { $0.id == app.id }) {
            out[index] = app
        } else {
            out.append(app)
        }
        return out
    }
}
