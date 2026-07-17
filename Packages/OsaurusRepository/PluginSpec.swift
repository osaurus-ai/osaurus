//
//  PluginSpec.swift
//  osaurus
//
//  Defines the plugin specification format and version resolution logic for plugin artifacts.
//

import Foundation

public struct MinisignInfo: Codable, Equatable, Sendable {
    public let signature: String
    public let key_id: String?
}

public struct PluginArtifact: Codable, Equatable, Sendable {
    public let os: String
    public let arch: String
    public let min_macos: String?
    public let url: String
    public let sha256: String
    public let minisign: MinisignInfo?
    public let size: Int?
}

public struct PluginRequirements: Codable, Equatable, Sendable {
    public let osaurus_min_version: SemanticVersion?
}

public struct PluginVersionEntry: Codable, Equatable, Sendable {
    public let version: SemanticVersion
    public let release_date: String?
    public let notes: String?
    public let artifacts: [PluginArtifact]
    public let requires: PluginRequirements?
}

// Registry-side capabilities summary (informational)
public struct RegistryCapabilities: Codable, Equatable, Sendable {
    public struct ToolSummary: Codable, Equatable, Sendable {
        public let name: String
        public let description: String

        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }
    public struct SkillSummary: Codable, Equatable, Sendable {
        public let name: String
        public let description: String

        public init(name: String, description: String) {
            self.name = name
            self.description = description
        }
    }
    public let tools: [ToolSummary]?
    public let skills: [SkillSummary]?

    public init(tools: [ToolSummary]? = nil, skills: [SkillSummary]? = nil) {
        self.tools = tools
        self.skills = skills
    }
}

public struct PluginSpec: Codable, Equatable, Sendable {
    public let plugin_id: String
    public let name: String?
    public let description: String?
    public let homepage: String?
    public let license: String?
    public let authors: [String]?
    public let public_keys: [String: String]?
    public let capabilities: RegistryCapabilities?

    public let versions: [PluginVersionEntry]

    public init(
        plugin_id: String,
        name: String? = nil,
        description: String? = nil,
        homepage: String? = nil,
        license: String? = nil,
        authors: [String]? = nil,
        public_keys: [String: String]? = nil,
        capabilities: RegistryCapabilities? = nil,
        versions: [PluginVersionEntry] = []
    ) {
        self.plugin_id = plugin_id
        self.name = name
        self.description = description
        self.homepage = homepage
        self.license = license
        self.authors = authors
        self.public_keys = public_keys
        self.capabilities = capabilities
        self.versions = versions
    }
}

public enum Platform: String {
    case macos
}

public enum CPUArch: String {
    case arm64
}

public struct PluginResolution {
    public let spec: PluginSpec
    public let version: PluginVersionEntry
    public let artifact: PluginArtifact
}

public enum PluginResolutionError: Error {
    case noMatchingArtifact
    case noVersions
}

public extension PluginSpec {
    func resolveBestVersion(
        targetPlatform: Platform,
        targetArch: CPUArch,
        minimumOsaurusVersion: SemanticVersion?,
        preferredVersion: SemanticVersion? = nil,
        currentMacOSVersion: OperatingSystemVersion? = nil
    ) throws -> PluginResolution {
        guard !versions.isEmpty else { throw PluginResolutionError.noVersions }

        let filtered: [PluginVersionEntry] = versions.filter { entry in
            guard let req = entry.requires?.osaurus_min_version,
                let min = minimumOsaurusVersion
            else { return true }
            return min >= req
        }
        let sorted = filtered.sorted { $0.version > $1.version }

        func eligibleArtifact(in entry: PluginVersionEntry) -> PluginArtifact? {
            entry.artifacts.first { art in
                art.os == targetPlatform.rawValue
                    && art.arch == targetArch.rawValue
                    && Self.artifactSupportsMacOSVersion(art, current: currentMacOSVersion)
            }
        }

        if let preferred = preferredVersion {
            if let match = sorted.first(where: { $0.version == preferred }),
                let art = eligibleArtifact(in: match)
            {
                return PluginResolution(spec: self, version: match, artifact: art)
            }
        }

        for v in sorted {
            if let art = eligibleArtifact(in: v) {
                return PluginResolution(spec: self, version: v, artifact: art)
            }
        }
        throw PluginResolutionError.noMatchingArtifact
    }

    /// True when `artifact.min_macos` is satisfied by `current`. Fails open when
    /// the caller passes no current version, the artifact declares no minimum,
    /// or the declared minimum is unparseable (registry data problem — the
    /// artifact should not become uninstallable because of a typo the loader
    /// would also ignore).
    internal static func artifactSupportsMacOSVersion(
        _ artifact: PluginArtifact,
        current: OperatingSystemVersion?
    ) -> Bool {
        guard let current,
            let declared = artifact.min_macos, !declared.isEmpty,
            let required = parseMacOSVersion(declared)
        else { return true }
        return osVersion(current, isAtLeast: required)
    }

    /// Parses a "MAJOR[.MINOR[.PATCH]]" macOS version string. Trailing
    /// components default to zero (`"14"` / `"14.5"` / `"14.5.1"` are all
    /// valid). Returns nil when no leading integer can be parsed.
    internal static func parseMacOSVersion(_ s: String) -> OperatingSystemVersion? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let major = parts.first.flatMap(Int.init) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let patch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        return OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }

    /// `OperatingSystemVersion` has no `Comparable` conformance; lexicographic
    /// comparison keeps this testable with injected values.
    internal static func osVersion(
        _ current: OperatingSystemVersion,
        isAtLeast required: OperatingSystemVersion
    ) -> Bool {
        if current.majorVersion != required.majorVersion {
            return current.majorVersion > required.majorVersion
        }
        if current.minorVersion != required.minorVersion {
            return current.minorVersion > required.minorVersion
        }
        return current.patchVersion >= required.patchVersion
    }
}
