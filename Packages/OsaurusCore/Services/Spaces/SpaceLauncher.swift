//
//  SpaceLauncher.swift
//  osaurus
//
//  Applies Space changes at process start, before any app singleton reads
//  `UserDefaults`, `OsaurusPaths.root()`, or the Keychain. Menu actions only
//  record intent in the registry and relaunch; everything destructive runs
//  here, where no live service can race it.
//

import Foundation
import OsaurusRepository

public enum SpaceLauncher {
    /// Preference keys a new or reset Space inherits from the domain it
    /// replaces: update settings (Sparkle) and the app language. Everything
    /// else, including onboarding and consent, starts fresh.
    static func isCarriedOverKey(_ key: String) -> Bool {
        key.hasPrefix("SU") || key == "AppleLanguages"
    }

    /// Called from `OsaurusMain.main()` after
    /// `DevelopmentDesignInspector.prepareProcess()`.
    public static func prepareProcess() {
        guard SpaceRegistry.isEnabled, let bundleId = Bundle.main.bundleIdentifier else { return }
        let document: OsaurusSpaceRegistryDocument?
        do {
            document = try SpaceRegistry.load()
        } catch {
            // Never overwrite a registry we could not read; run in Default.
            print("[Spaces] Could not read \(SpaceRegistry.registryFile().path): \(error)")
            SpaceRegistry.pinActiveSpace(SpaceRegistry.defaultSpaceId)
            return
        }
        guard var document else { return }
        let active = prepare(&document, bundleId: bundleId, defaults: .standard)
        SpaceRegistry.pinActiveSpace(active)
    }

    /// Applies pending work and the preferences swap for `bundleId`, saving
    /// the registry after each step. Returns the Space the process runs in.
    @discardableResult
    static func prepare(
        _ document: inout OsaurusSpaceRegistryDocument,
        bundleId: String,
        defaults: UserDefaults,
        fileManager fm: FileManager = .default
    ) -> String {
        var liveDomainIsStale = false

        let operations = document.pending[bundleId] ?? []
        if !operations.isEmpty {
            for operation in operations {
                apply(operation, to: &document, bundleId: bundleId, fileManager: fm)
                if document.defaultsOwnerId(bundleId: bundleId) == operation.spaceId {
                    liveDomainIsStale = true
                }
            }
            document.pending[bundleId] = nil
            persist(document)
        }

        if let swap = document.swapInProgress[bundleId] {
            // A crash after parking but before the swap finished: the parked
            // file is authoritative, so finish loading the target without
            // parking the live domain again.
            let target = loadPreferences(spaceId: swap.to, bundleId: bundleId, seedFrom: defaults)
            defaults.setPersistentDomain(target, forName: bundleId)
            document.defaultsOwner[bundleId] = swap.to
            document.swapInProgress[bundleId] = nil
            liveDomainIsStale = false
            persist(document)
        }

        let target = document.activeSpaceId(bundleId: bundleId)
        let owner = document.defaultsOwnerId(bundleId: bundleId)
        let ownerExists = owner == SpaceRegistry.defaultSpaceId || document.space(id: owner) != nil

        if owner != target {
            if ownerExists && !liveDomainIsStale {
                let live = defaults.persistentDomain(forName: bundleId) ?? [:]
                do {
                    try writePreferences(live, spaceId: owner, bundleId: bundleId, fileManager: fm)
                } catch {
                    // Without a parked copy the swap would lose the owner's
                    // preferences; stay in the owner's Space instead.
                    print("[Spaces] Could not park preferences for \(owner): \(error)")
                    document.active[bundleId] = owner
                    persist(document)
                    return owner
                }
            }
            document.swapInProgress[bundleId] = OsaurusSpaceSwap(from: owner, to: target)
            persist(document)
            let next = loadPreferences(spaceId: target, bundleId: bundleId, seedFrom: defaults)
            defaults.setPersistentDomain(next, forName: bundleId)
            document.defaultsOwner[bundleId] = target
            document.swapInProgress[bundleId] = nil
            persist(document)
        } else if liveDomainIsStale {
            defaults.setPersistentDomain(seed(from: defaults, bundleId: bundleId), forName: bundleId)
            document.defaultsOwner[bundleId] = target
            persist(document)
        }
        return target
    }

    // MARK: - Pending operations

    private static func apply(
        _ operation: OsaurusSpacePendingOperation,
        to document: inout OsaurusSpaceRegistryDocument,
        bundleId: String,
        fileManager fm: FileManager
    ) {
        let id = operation.spaceId
        guard id != SpaceRegistry.defaultSpaceId, SpaceRegistry.isValidSpaceId(id) else { return }
        switch operation.kind {
        case .reset:
            wipeContents(of: id, fileManager: fm)
            print("[Spaces] Reset Space \(id)")
        case .delete:
            removeSpace(id, from: &document, fileManager: fm)
            print("[Spaces] Deleted Space \(id)")
        }
    }

    /// Removes a Space's data, parked preferences, and Keychain entries,
    /// keeping it registered so it reopens empty.
    static func wipeContents(of spaceId: String, fileManager fm: FileManager = .default) {
        guard spaceId != SpaceRegistry.defaultSpaceId, SpaceRegistry.isValidSpaceId(spaceId) else { return }
        let folder = SpaceRegistry.spaceDirectory(for: spaceId)
        for sub in ["data", "preferences"] {
            removeIfPresent(folder.appendingPathComponent(sub, isDirectory: true), fileManager: fm)
        }
        SpaceKeychainScope.wipe(spaceId: spaceId)
    }

    /// Unregisters a Space and deletes everything it owns.
    static func removeSpace(
        _ spaceId: String,
        from document: inout OsaurusSpaceRegistryDocument,
        fileManager fm: FileManager = .default
    ) {
        guard spaceId != SpaceRegistry.defaultSpaceId, SpaceRegistry.isValidSpaceId(spaceId) else { return }
        removeIfPresent(SpaceRegistry.spaceDirectory(for: spaceId), fileManager: fm)
        SpaceKeychainScope.wipe(spaceId: spaceId)
        document.spaces.removeAll { $0.id == spaceId }
        for (bundle, active) in document.active where active == spaceId {
            document.active[bundle] = SpaceRegistry.defaultSpaceId
        }
    }

    /// Rename-then-delete, like factory reset: the rename is atomic, so a
    /// partial delete never leaves a half-populated folder at the real path.
    private static func removeIfPresent(_ url: URL, fileManager fm: FileManager) {
        guard fm.fileExists(atPath: url.path) else { return }
        let doomed = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).removing-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.moveItem(at: url, to: doomed)
            try fm.removeItem(at: doomed)
        } catch {
            print("[Spaces] Failed to remove \(url.path): \(error)")
        }
    }

    // MARK: - Preferences

    private static func loadPreferences(
        spaceId: String,
        bundleId: String,
        seedFrom defaults: UserDefaults
    ) -> [String: Any] {
        let url = SpaceRegistry.preferencesFile(spaceId: spaceId, bundleId: bundleId)
        if let data = try? Data(contentsOf: url),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        {
            return plist
        }
        return seed(from: defaults, bundleId: bundleId)
    }

    static func seed(from defaults: UserDefaults, bundleId: String) -> [String: Any] {
        (defaults.persistentDomain(forName: bundleId) ?? [:]).filter { isCarriedOverKey($0.key) }
    }

    private static func writePreferences(
        _ domain: [String: Any],
        spaceId: String,
        bundleId: String,
        fileManager fm: FileManager
    ) throws {
        let url = SpaceRegistry.preferencesFile(spaceId: spaceId, bundleId: bundleId)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: domain, format: .binary, options: 0)
        try data.write(to: url, options: .atomic)
    }

    private static func persist(_ document: OsaurusSpaceRegistryDocument) {
        do {
            try SpaceRegistry.save(document)
        } catch {
            print("[Spaces] Could not save \(SpaceRegistry.registryFile().path): \(error)")
        }
    }
}
