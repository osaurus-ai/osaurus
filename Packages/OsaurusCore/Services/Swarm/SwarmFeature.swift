//
//  SwarmFeature.swift
//  osaurus
//
//  Whether this build can run Osaurus Swarm, which backend it uses, and the
//  model-id scheme Swarm pool models use in every picker and the HTTP API.
//

import Foundation

enum SwarmFeature {
    /// Launch environment switch for the in-process simulated nodes (dev and
    /// live-proof builds without the vendored library).
    static let simulatorEnvironmentKey = "OSAURUS_SWARM_SIMULATOR"

    static var simulatorRequested: Bool {
        ProcessInfo.processInfo.environment[simulatorEnvironmentKey] == "1"
    }

    /// The vendored Swarm master library is linked into this build.
    static var libraryAvailable: Bool {
        #if canImport(OsaurusSwarm)
            return true
        #else
            return false
        #endif
    }

    /// Swarm shows in Settings and pickers only when a backend exists.
    static var isAvailable: Bool {
        libraryAvailable || simulatorRequested
    }

    /// The simulator when explicitly requested (dev/proof launches), else
    /// the library when it is linked, else nothing.
    static func makeBackend() -> (any SwarmMasterBackend)? {
        if simulatorRequested { return SwarmSimulatorBackend() }
        #if canImport(OsaurusSwarm)
            return SwarmLibraryBackend()
        #else
            return nil
        #endif
    }

    /// Library / simulator state (identity, pairing credentials it keeps
    /// outside the keystore, simulator state).
    static func stateDirectory() -> URL {
        OsaurusPaths.root().appendingPathComponent("swarm", isDirectory: true)
    }
}

/// `osaurus-swarm/<pool-slug>/<model-id>`: how a pool × model appears as a
/// model id. The model id is the node's own (a Hugging Face repo id, which
/// itself contains a slash), so parsing splits only the first two segments.
/// Renaming a pool changes its slug, as renaming a provider changes its
/// prefix.
enum SwarmModelIdentity {
    static let providerName = "Osaurus Swarm"
    /// Fixed provider identity for picker grouping, favourites and spawn ids.
    static let providerId = UUID(uuidString: "5A7A3D1E-0C55-4F0B-9B1A-5357A2B30001")!

    static var prefix: String { RemoteProviderManager.pickerPrefix(for: providerName) }

    static func slug(forPoolName name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var lastWasDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "pool" : out
    }

    static func make(poolName: String, modelId: String) -> String {
        "\(prefix)/\(slug(forPoolName: poolName))/\(modelId)"
    }

    /// The pool slug and model id after the provider prefix, or the
    /// unprefixed `<pool-slug>/<model-id>` remainder a spawn identity holds.
    static func parse(_ id: String) -> (poolSlug: String, modelId: String)? {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = prefix + "/"
        guard trimmed.lowercased().hasPrefix(head) else { return nil }
        return parseUnprefixed(String(trimmed.dropFirst(head.count)))
    }

    static func parseUnprefixed(_ rest: String) -> (poolSlug: String, modelId: String)? {
        guard let slash = rest.firstIndex(of: "/") else { return nil }
        let slug = String(rest[..<slash])
        let model = String(rest[rest.index(after: slash)...])
        guard !slug.isEmpty, !model.isEmpty else { return nil }
        return (slug, model)
    }

    /// "Qwen3.6-27B-JANG_4M" from "OsaurusAI/Qwen3.6-27B-JANG_4M".
    static func shortModelName(_ modelId: String) -> String {
        modelId.split(separator: "/").last.map(String.init) ?? modelId
    }
}
