//
//  BundleOnboarding.swift
//  osaurus
//
//  What a bundle asks of Osaurus's first-run onboarding: skip the intro, and
//  leave out some or all of the starter teammates. Declared in the
//  manifest's `onboarding` object or with `osaurus import` flags, carried to
//  the app on the queued request, and kept per bundle in
//  `import/onboarding.json` so `remove --bundle` can take it back.
//

import Foundation

/// The starter teammates a bundle may leave out, by the names the app's
/// `Teammate` enum uses. A test in the app keeps the two lists equal.
public enum BundleTeammates {
    public static let names = ["planner", "courier", "keeper", "scout", "builder"]
    public static let all = "all"
}

/// The teammates a bundle leaves out. `all` stays its own case so a
/// teammate added in a later release is left out too.
public enum TeammateExclusion: Codable, Sendable, Equatable {
    case all
    case names([String])

    public static let none = TeammateExclusion.names([])

    public var isEmpty: Bool { self == .none }

    public func excludes(_ teammate: String) -> Bool {
        switch self {
        case .all: return true
        case .names(let names): return names.contains(teammate.lowercased())
        }
    }

    /// `all` on either side wins; names are a union.
    public func union(_ other: TeammateExclusion) -> TeammateExclusion {
        switch (self, other) {
        case (.all, _), (_, .all): return .all
        case (.names(let a), .names(let b)): return .normalized(a + b)
        }
    }

    /// Lowercased, trimmed, deduplicated and sorted. A lone `all` becomes
    /// `.all`; `all` next to names is kept so `problems` can report it.
    public static func normalized(_ raw: [String]) -> TeammateExclusion {
        let names = Array(
            Set(raw.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        ).sorted()
        return names == [BundleTeammates.all] ? .all : .names(names)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == BundleTeammates.all else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "expected \"all\" or a list of teammate names.")
            }
            self = .all
        } else if let list = try? container.decode([String].self) {
            self = .normalized(list)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "expected \"all\" or a list of teammate names.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .all: try container.encode(BundleTeammates.all)
        case .names(let names): try container.encode(names)
        }
    }

    /// Names that are not teammates, with a did-you-mean hint, and `all`
    /// mixed with names.
    public func problems(label: String) -> [String] {
        guard case .names(let names) = self else { return [] }
        var out: [String] = []
        if names.contains(BundleTeammates.all) {
            out.append("\(label): \"all\" can't be combined with teammate names; use \"all\" on its own.")
        }
        for name in names where name != BundleTeammates.all && !BundleTeammates.names.contains(name) {
            let hint = BundleTeammates.names.min {
                OsaurusBundle.editDistance($0, name) < OsaurusBundle.editDistance($1, name)
            }
            let suggestion = hint.flatMap { OsaurusBundle.editDistance($0, name) <= 3 ? " Did you mean `\($0)`?" : nil }
            out.append(
                "\(label): unknown teammate `\(name)`.\(suggestion ?? "") Teammates are "
                    + BundleTeammates.names.joined(separator: ", ") + ", or \"all\".")
        }
        return out
    }
}

public struct BundleOnboarding: Codable, Sendable, Equatable {
    /// Skip the welcome step and the in-chat walkthrough. The AI setup step
    /// still runs.
    public var skip: Bool
    public var excludeTeammates: TeammateExclusion

    public init(skip: Bool = false, excludeTeammates: TeammateExclusion = .none) {
        self.skip = skip
        self.excludeTeammates = excludeTeammates
    }

    public var isEmpty: Bool { !skip && excludeTeammates.isEmpty }

    /// `skip` from either side; exclusions are a union and `all` wins.
    public func merged(with other: BundleOnboarding) -> BundleOnboarding {
        BundleOnboarding(skip: skip || other.skip, excludeTeammates: excludeTeammates.union(other.excludeTeammates))
    }

    public func problems(label: String = "onboarding") -> [String] {
        excludeTeammates.problems(label: "\(label).exclude_teammates")
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skip = try c.decodeIfPresent(Bool.self, forKey: .skip) ?? false
        excludeTeammates = try c.decodeIfPresent(TeammateExclusion.self, forKey: .excludeTeammates) ?? .none
    }

    private enum CodingKeys: String, CodingKey {
        case skip, excludeTeammates
    }

    /// The manifest spells its keys in snake case and is read with a plain
    /// decoder; the queue's coders convert the case themselves.
    struct ManifestEntry: Codable {
        var skip: Bool?
        var excludeTeammates: TeammateExclusion?

        enum CodingKeys: String, CodingKey {
            case skip
            case excludeTeammates = "exclude_teammates"
        }

        init(_ value: BundleOnboarding) {
            skip = value.skip
            excludeTeammates = value.excludeTeammates
        }

        var value: BundleOnboarding {
            BundleOnboarding(skip: skip ?? false, excludeTeammates: excludeTeammates ?? .none)
        }
    }

    static let allowedManifestKeys: Set<String> = ["skip", "exclude_teammates"]
}

// MARK: - Per-bundle record

extension ImportQueue {
    public static func onboardingURL() -> URL { root().appendingPathComponent("onboarding.json") }

    /// A list rather than a map: the coders' snake-case strategy would
    /// rewrite bundle ids used as keys.
    private struct OnboardingFile: Codable {
        struct Entry: Codable {
            var bundleId: String
            var onboarding: BundleOnboarding
        }
        var version: Int
        var bundles: [Entry]
    }

    /// What each bundle asked of onboarding, keyed by bundle id. Written
    /// only by the app.
    public static func loadOnboarding() -> [String: BundleOnboarding] {
        guard let data = try? Data(contentsOf: onboardingURL()),
            let file = try? decoder().decode(OnboardingFile.self, from: data)
        else { return [:] }
        return Dictionary(file.bundles.map { ($0.bundleId, $0.onboarding) }, uniquingKeysWith: { _, last in last })
    }

    public static func saveOnboarding(_ bundles: [String: BundleOnboarding]) throws {
        try FileManager.default.createDirectory(
            at: root(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let entries = bundles.sorted { $0.key < $1.key }.map { OnboardingFile.Entry(bundleId: $0.key, onboarding: $0.value) }
        try encoder().encode(OnboardingFile(version: 1, bundles: entries))
            .write(to: onboardingURL(), options: .atomic)
    }

    /// Every bundle's asks combined: skip if any asks, the union of the
    /// exclusions. Requests still in the queue count as applied: the
    /// onboarding window opens before launch has applied them.
    public static func effectiveOnboarding() -> BundleOnboarding {
        var bundles = loadOnboarding()
        for item in pending() {
            if item.request.forgetsOnboarding == true {
                bundles.removeValue(forKey: item.request.bundleId)
            } else if let onboarding = item.request.onboarding, !onboarding.isEmpty {
                bundles[item.request.bundleId] = onboarding
            }
        }
        return bundles.values.reduce(BundleOnboarding()) { $0.merged(with: $1) }
    }
}
