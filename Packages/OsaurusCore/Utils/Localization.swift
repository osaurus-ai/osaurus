import Foundation

/// Localized string helper for OsaurusCore SwiftPM package.
/// Looks up strings in the package's own bundle (Resources/Localizable.xcstrings)
/// instead of the main app bundle. This is required because OsaurusCore ships
/// its Localizable.xcstrings as a SwiftPM resource via `.process("Resources")`.
public func L(_ key: String.LocalizationValue, comment: StaticString? = nil) -> String {
    String(localized: key, bundle: .module, comment: comment)
}

/// Memoized `L` for a plain, non-interpolated string key.
///
/// `String(localized:)` re-resolves the key through the bundle's xcstrings
/// catalog on every call. Built-in display names are localized this way from
/// SwiftUI body getters — once per chat tab, sidebar row and picker entry, on
/// every render — and that lookup showed up as the leaf of main-thread hang
/// samples.
///
/// Only use this for keys drawn from a fixed, bounded set (built-in agent
/// names and descriptions). Interpolated or user-supplied keys must keep
/// using `L` so the cache cannot grow without bound.
///
/// The cache cannot go stale: the only input that changes the result for a
/// given key is the selected locale, and a locale change clears it.
public func LCached(_ key: String) -> String {
    guard !key.isEmpty else { return key }
    LocalizedStringMemo.shared.installObserverIfNeeded()
    if let hit = LocalizedStringMemo.shared.value(for: key) { return hit }
    let resolved = L(String.LocalizationValue(key))
    LocalizedStringMemo.shared.store(resolved, for: key)
    return resolved
}

/// Backing store for `LCached`.
private final class LocalizedStringMemo: @unchecked Sendable {
    static let shared = LocalizedStringMemo()

    private let lock = NSLock()
    private var entries: [String: String] = [:]
    private var observerInstalled = false

    func value(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    func store(_ value: String, for key: String) {
        lock.lock()
        entries[key] = value
        lock.unlock()
    }

    func installObserverIfNeeded() {
        lock.lock()
        let needed = !observerInstalled
        if needed { observerInstalled = true }
        lock.unlock()
        guard needed else { return }
        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.entries.removeAll()
            self.lock.unlock()
        }
    }
}
