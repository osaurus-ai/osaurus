import Foundation

/// Epoch ownership prevents an old background read from publishing stale
/// metadata or clearing a newer lookup's in-flight reservation.
final class ModelMetadataCache<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Value] = [:]
    private var generation: UInt64 = 0
    private var backgroundReads: [String: UInt64] = [:]

    func lookup(_ key: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func begin(_ key: String, background: Bool) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        if background {
            guard backgroundReads[key] == nil else { return nil }
            backgroundReads[key] = generation
        }
        return generation
    }

    @discardableResult
    func finish(_ key: String, generation started: UInt64, value: Value?, background: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard generation == started else { return false }
        if background {
            guard backgroundReads[key] == started else { return false }
            backgroundReads.removeValue(forKey: key)
        }
        if let value { values.updateValue(value, forKey: key) }
        return true
    }

    func invalidate() {
        lock.lock()
        generation &+= 1
        values.removeAll()
        backgroundReads.removeAll()
        lock.unlock()
    }
}

