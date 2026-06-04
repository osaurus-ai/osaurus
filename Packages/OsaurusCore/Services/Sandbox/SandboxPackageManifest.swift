import Foundation

/// Host-side record of which packages have been installed into an agent's
/// sandbox, broken down by manager. Two writers feed it:
///
///   1. `SandboxAgentProvisioner` seeds it once per provision via
///      `reconcile(...)` — a cheap `apk` / `pip` / `npm` listing that
///      captures the real container state (including anything installed
///      with a bare `sandbox_exec` outside the install tool).
///   2. `sandbox_install` appends successful installs via `record(...)`.
///
/// `SystemPromptComposer` reads it (`installed(agentId:)`) and surfaces a
/// compact, capped line in the static system-prompt prefix so the model
/// knows what's already available without re-probing. Because the prompt
/// line lives in the cached prefix, it reflects manifest state as of
/// session start — within-session installs are already visible to the
/// model through each install tool's success result, and the manifest
/// update keeps the next session accurate. No mid-session prefix churn.
///
/// Persisted as `~/.osaurus/agents/<uuid>/installed-packages.json`.
/// Thread-safe and synchronous so it can be called from the `@Sendable`
/// `onSuccess` callback inside the install recovery harness.
public final class SandboxPackageManifest: @unchecked Sendable {
    public static let shared = SandboxPackageManifest()

    public enum Manager: String, Codable, CaseIterable, Sendable {
        case apk
        case pip
        case npm
    }

    /// Decoded manifest shape — name lists per manager. Stored sorted +
    /// de-duplicated so the on-disk form and prompt rendering are stable.
    public struct Installed: Codable, Sendable, Equatable {
        public var apk: [String]
        public var pip: [String]
        public var npm: [String]

        public init(apk: [String] = [], pip: [String] = [], npm: [String] = []) {
            self.apk = apk
            self.pip = pip
            self.npm = npm
        }

        public func names(for manager: Manager) -> [String] {
            switch manager {
            case .apk: return apk
            case .pip: return pip
            case .npm: return npm
            }
        }

        public var isEmpty: Bool { apk.isEmpty && pip.isEmpty && npm.isEmpty }
    }

    private let lock = NSLock()
    /// Write-through cache, keyed by agent UUID. Lazily loaded from disk on
    /// first touch so repeated prompt reads don't re-hit the filesystem.
    private var cache: [UUID: Installed] = [:]

    private init() {}

    // MARK: - Reads

    /// The installed-package manifest for an agent. Returns an empty value
    /// when the id is malformed or nothing has been recorded yet.
    public func installed(agentId: String) -> Installed {
        guard let uuid = UUID(uuidString: agentId) else { return Installed() }
        return installed(agentId: uuid)
    }

    public func installed(agentId: UUID) -> Installed {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked(agentId)
    }

    // MARK: - Writes

    /// Append a successful install to the manifest (merged + de-duplicated).
    /// No-op on a malformed id or empty package list.
    public func record(agentId: String, manager: Manager, packages: [String]) {
        guard let uuid = UUID(uuidString: agentId) else { return }
        let cleaned = normalize(packages)
        guard !cleaned.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }
        var current = loadLocked(uuid)
        merge(&current, manager: manager, adding: cleaned)
        persistLocked(uuid, current)
    }

    /// Replace the manifest with freshly-observed container truth. Called
    /// once per provision so drift (manual `sandbox_exec` installs, a
    /// rebuilt container) is reconciled. Passing `nil` for a manager leaves
    /// that manager's list untouched (e.g. when the listing query failed).
    public func reconcile(
        agentId: String,
        apk: [String]?,
        pip: [String]?,
        npm: [String]?
    ) {
        guard let uuid = UUID(uuidString: agentId) else { return }
        lock.lock()
        defer { lock.unlock() }
        var current = loadLocked(uuid)
        if let apk { current.apk = normalize(apk) }
        if let pip { current.pip = normalize(pip) }
        if let npm { current.npm = normalize(npm) }
        persistLocked(uuid, current)
    }

    /// Drop an agent's manifest (host file + cache). Mirrors how the
    /// provisioner clears other per-agent host state on unprovision.
    public func clear(agentId: String) {
        guard let uuid = UUID(uuidString: agentId) else { return }
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: uuid)
        try? FileManager.default.removeItem(at: OsaurusPaths.agentPackageManifestFile(for: uuid))
    }

    // MARK: - Internals

    private func merge(_ installed: inout Installed, manager: Manager, adding: [String]) {
        switch manager {
        case .apk: installed.apk = normalize(installed.apk + adding)
        case .pip: installed.pip = normalize(installed.pip + adding)
        case .npm: installed.npm = normalize(installed.npm + adding)
        }
    }

    /// Trim, drop blanks, de-duplicate (case-insensitively), and sort.
    private func normalize(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in names {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted { out.append(trimmed) }
        }
        return out.sorted { $0.lowercased() < $1.lowercased() }
    }

    /// Caller must hold `lock`. Returns the cached value, loading from disk
    /// (and caching) on first access.
    private func loadLocked(_ id: UUID) -> Installed {
        if let cached = cache[id] { return cached }
        let url = OsaurusPaths.agentPackageManifestFile(for: id)
        let loaded: Installed
        if let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(Installed.self, from: data)
        {
            loaded = decoded
        } else {
            loaded = Installed()
        }
        cache[id] = loaded
        return loaded
    }

    /// Caller must hold `lock`. Updates the cache and best-effort writes the
    /// file (creating the agent directory if needed).
    private func persistLocked(_ id: UUID, _ value: Installed) {
        cache[id] = value
        let url = OsaurusPaths.agentPackageManifestFile(for: id)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
