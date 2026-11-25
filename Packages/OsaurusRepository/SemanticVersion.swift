//
//  SemanticVersion.swift
//  osaurus
//
//  Implements semantic versioning (SemVer) parsing and comparison with support for prerelease and build metadata.
//

import Foundation

public struct SemanticVersion: Codable, Hashable, Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?
    public let build: String?

    public var description: String {
        var s = "\(major).\(minor).\(patch)"
        if let pre = prerelease, !pre.isEmpty { s += "-\(pre)" }
        if let b = build, !b.isEmpty { s += "+\(b)" }
        return s
    }

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil, build: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.build = build
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let s = try container.decode(String.self)
        guard let parsed = SemanticVersion.parse(s) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid semver: \(s)")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (l?, r?):
            return comparePrerelease(l, r) < 0
        }
    }

    /// Equality and hashing follow SemVer precedence rather than raw field
    /// equality. Build metadata is ignored (SemVer §10), and two versions are
    /// equal exactly when neither orders before the other. Deriving `==` from
    /// `<` guarantees the `Comparable` total-order contract holds for every
    /// pair — including build-metadata-only differences (`1.0.0+a` vs
    /// `1.0.0+b`) and numerically-equal prerelease identifiers (`1.0.0-alpha.1`
    /// vs `1.0.0-alpha.01`), which the synthesized member-wise `==` reported
    /// as unequal even though `<` ranked neither below the other (so none of
    /// `<`, `>`, `==` held).
    public static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    /// Hashes only the precedence-significant core. Prerelease and build are
    /// omitted so that values which `==` deems equal (e.g. build-only or
    /// `1`/`01` prerelease differences) always share a hash, as `Hashable`
    /// requires. Versions sharing a core but differing in precedence
    /// (`1.0.0` vs `1.0.0-alpha`) hash-collide, which is permitted.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(major)
        hasher.combine(minor)
        hasher.combine(patch)
    }

    private static func comparePrerelease(_ l: String, _ r: String) -> Int {
        let lParts = l.split(separator: ".").map(String.init)
        let rParts = r.split(separator: ".").map(String.init)
        let count = max(lParts.count, rParts.count)
        for i in 0 ..< count {
            let li = i < lParts.count ? lParts[i] : ""
            let ri = i < rParts.count ? rParts[i] : ""
            let lIsNum = Int(li) != nil
            let rIsNum = Int(ri) != nil
            if lIsNum && rIsNum {
                let ln = Int(li) ?? 0
                let rn = Int(ri) ?? 0
                if ln != rn { return ln < rn ? -1 : 1 }
            } else if lIsNum {
                return -1
            } else if rIsNum {
                return 1
            } else if li != ri {
                return li < ri ? -1 : 1
            }
        }
        return 0
    }

    public static func parse(_ s: String) -> SemanticVersion? {
        let buildSplit = s.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let withoutBuild = buildSplit.first ?? s
        let build = buildSplit.count == 2 ? buildSplit[1] : nil

        let preSplit = withoutBuild.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(
            String.init
        )
        let core = preSplit.first ?? withoutBuild
        let prerelease = preSplit.count == 2 ? preSplit[1] : nil

        // SemVer §9: a prerelease or build section, once introduced by its
        // separator, must be a series of non-empty dot-separated identifiers.
        // The permissive split above keeps empty subsequences, so without this
        // guard `1.0.0-`, `1.0.0+`, and `1.0.0-a..b` would parse into lossy
        // values that render as `1.0.0` yet compare unequal to it.
        if let prerelease, !isValidIdentifierSeries(prerelease) { return nil }
        if let build, !isValidIdentifierSeries(build) { return nil }

        let nums = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard nums.count == 3,
            let maj = Int(nums[0]),
            let min = Int(nums[1]),
            let pat = Int(nums[2])
        else { return nil }
        return SemanticVersion(major: maj, minor: min, patch: pat, prerelease: prerelease, build: build)
    }

    /// True when `s` is a non-empty series of non-empty dot-separated
    /// identifiers — the structural rule SemVer §9 imposes on a prerelease or
    /// build section.
    private static func isValidIdentifierSeries(_ s: String) -> Bool {
        !s.isEmpty
            && s.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty }
    }
}
