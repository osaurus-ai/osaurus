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

        let nums = core.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard nums.count == 3,
            let maj = Int(nums[0]),
            let min = Int(nums[1]),
            let pat = Int(nums[2])
        else { return nil }
        return SemanticVersion(major: maj, minor: min, patch: pat, prerelease: prerelease, build: build)
    }
}
