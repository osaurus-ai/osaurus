//
//  BundleSettings.swift
//  osaurus
//
//  The Osaurus settings a bundle may change, under the manifest's
//  `settings` object. Each one is an import item of kind `setting`, named
//  by its manifest key. The list is deliberately short: a setting joins it
//  only with a type, a check, and a plain-language risk line for any value
//  that loosens security. Shared by the CLI and the app.
//

import Foundation

/// A setting value as written in the manifest.
public enum BundleSettingValue: Codable, Sendable, Equatable, Hashable, CustomStringConvertible {
    case bool(Bool)
    case strings([String])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let flag = try? c.decode(Bool.self) {
            self = .bool(flag)
        } else if let list = try? c.decode([String].self) {
            self = .strings(list)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "expected true, false, or a list of strings.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let flag): try c.encode(flag)
        case .strings(let list): try c.encode(list)
        }
    }

    public var description: String {
        switch self {
        case .bool(let flag): return flag ? "on" : "off"
        case .strings(let list): return list.isEmpty ? "none" : list.joined(separator: ", ")
        }
    }
}

public struct BundleSetting: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// An on/off switch. The bundle's value replaces the current one.
        case toggle
        /// A list of browser origins. The bundle's origins are added to the
        /// current list; a bundle never removes an origin.
        case origins
    }

    /// The manifest key, also the item name in receipts and results.
    public enum ID: String, Sendable, CaseIterable {
        case requireLocalAccessKey = "require_local_access_key"
        case allowedOrigins = "allowed_origins"
    }

    public let id: ID
    /// The settings-catalog id of the control (`SettingsSearchIndex`).
    public let catalogId: String
    /// The control's on-screen title.
    public let title: String
    /// Where the control is, for messages.
    public let location: String
    public let kind: Kind

    public var key: String { id.rawValue }

    public static let requireLocalAccessKey = BundleSetting(
        id: .requireLocalAccessKey,
        catalogId: "server.localAccessKey",
        title: "Require Access Key for Local Admin Routes",
        location: "Server → Settings → Authentication",
        kind: .toggle)

    public static let allowedOrigins = BundleSetting(
        id: .allowedOrigins,
        catalogId: "server.cors",
        title: "Allowed Origins (CORS)",
        location: "Server → Settings → Connection",
        kind: .origins)

    public static let all: [BundleSetting] = [requireLocalAccessKey, allowedOrigins]

    public static func named(_ key: String) -> BundleSetting? {
        ID(rawValue: key.lowercased()).flatMap { id in all.first { $0.id == id } }
    }

    /// Problems with a value for this setting, labelled for the manifest.
    public func problems(with value: BundleSettingValue) -> [String] {
        let label = "settings.\(key)"
        switch (kind, value) {
        case (.toggle, .bool):
            return []
        case (.toggle, .strings):
            return ["\(label): must be true or false."]
        case (.origins, .bool):
            return ["\(label): must be a list of origins, like [\"https://app.example.com\"]."]
        case (.origins, .strings(let list)):
            if list.isEmpty { return ["\(label): list at least one origin."] }
            return list.compactMap { Self.originProblem($0, label: label) }
        }
    }

    /// Plain-language high-risk changes the value makes. Applying any of
    /// them needs `--yes`.
    public func risks(of value: BundleSettingValue) -> [String] {
        switch (id, value) {
        case (.requireLocalAccessKey, .bool(false)):
            return ["Turns off \"\(title)\": apps on this Mac reach sessions, agents, MCP and config without a key"]
        case (.allowedOrigins, .strings(let list)):
            return list.map { "Lets web pages from \($0) call Osaurus on this Mac from a browser" }
        default:
            return []
        }
    }

    /// Whether `current` already has what the bundle asks for.
    public func isSatisfied(_ wanted: BundleSettingValue, by current: BundleSettingValue) -> Bool {
        switch (kind, wanted, current) {
        case (.origins, .strings(let want), .strings(let have)):
            return Set(want).isSubset(of: Set(have))
        default:
            return wanted == current
        }
    }

    /// The value to store so `current` has what the bundle asks for.
    public func applying(_ wanted: BundleSettingValue, to current: BundleSettingValue) -> BundleSettingValue {
        switch (kind, wanted, current) {
        case (.origins, .strings(let want), .strings(let have)):
            return .strings(have + want.filter { !have.contains($0) })
        default:
            return wanted
        }
    }

    /// `https://host` or `http://host:port`, written the way browsers send
    /// it: lowercase, no path, no trailing slash, no wildcard.
    static func originProblem(_ origin: String, label: String) -> String? {
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "*" || trimmed.contains("*") {
            return "\(label): \"\(origin)\" is a wildcard. List each origin by name."
        }
        guard let components = URLComponents(string: trimmed),
            let scheme = components.scheme, scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil
        else {
            return "\(label): \"\(origin)\" is not an origin. Write it like https://app.example.com."
        }
        if !components.path.isEmpty {
            return "\(label): \"\(origin)\" has a path. An origin is only scheme, host and port, "
                + "like https://app.example.com."
        }
        if trimmed != trimmed.lowercased() || trimmed != origin {
            return "\(label): write \"\(origin)\" in lowercase without spaces, the way browsers send it."
        }
        return nil
    }
}
