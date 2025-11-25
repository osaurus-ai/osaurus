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
    }
    public let tools: [ToolSummary]?
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
        preferredVersion: SemanticVersion? = nil
    ) throws -> PluginResolution {
        guard !versions.isEmpty else { throw PluginResolutionError.noVersions }

        let filtered: [PluginVersionEntry] = versions.filter { entry in
            guard let req = entry.requires?.osaurus_min_version,
                let min = minimumOsaurusVersion
            else { return true }
            return min >= req
        }
        let sorted = filtered.sorted { $0.version > $1.version }

        if let preferred = preferredVersion {
            if let match = sorted.first(where: { $0.version == preferred }),
                let art = match.artifacts.first(where: {
                    $0.os == targetPlatform.rawValue && $0.arch == targetArch.rawValue
                })
            {
                return PluginResolution(spec: self, version: match, artifact: art)
            }
        }

        for v in sorted {
            if let art = v.artifacts.first(where: { $0.os == targetPlatform.rawValue && $0.arch == targetArch.rawValue }
            ) {
                return PluginResolution(spec: self, version: v, artifact: art)
            }
        }
        throw PluginResolutionError.noMatchingArtifact
    }
}
