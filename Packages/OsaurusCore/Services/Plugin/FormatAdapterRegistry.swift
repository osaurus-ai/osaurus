//
//  FormatAdapterRegistry.swift
//  osaurus
//
//  Registry for plugin format adapter factories. It is separate from
//  `DocumentFormatRegistry` because plugin packs stream generic records while
//  the existing document stack returns typed `StructuredDocument` values.
//

import Foundation

/// Registry errors are explicit because duplicate plugin claims need to fail
/// during startup instead of silently changing format ownership.
public enum FormatAdapterRegistryError: LocalizedError, Equatable, Sendable {
    case emptyFormatIdentifier
    case duplicateRegistration(formatIdentifier: String)
    case unknownFormat(formatIdentifier: String)

    public var errorDescription: String? {
        switch self {
        case .emptyFormatIdentifier:
            return "Format adapter identifiers must not be empty"
        case .duplicateRegistration(let formatIdentifier):
            return "Format adapter '\(formatIdentifier)' is already registered"
        case .unknownFormat(let formatIdentifier):
            return "No format adapter is registered for '\(formatIdentifier)'"
        }
    }
}

/// The adapter registry owns factories instead of parser instances so each
/// open document receives isolated streaming state.
public final class FormatAdapterRegistry: @unchecked Sendable {
    public static let shared = FormatAdapterRegistry()

    private struct Registration {
        let formatIdentifier: String
        let detectionBytePatterns: [Data]
        let makeAdapter: @Sendable () -> any FormatAdapter
    }

    private let lock = NSLock()
    private var registrations: [String: Registration] = [:]
    private var registrationOrder: [String] = []

    /// Tests and plugin hosts need isolated registries so duplicate checks
    /// can be exercised without mutating process-wide plugin state.
    public init() {}

    /// Registers a factory rather than a singleton because adapter instances
    /// may hold per-document open state while streaming records.
    public func register<Adapter: FormatAdapter>(
        _ adapterType: Adapter.Type,
        makeAdapter: @escaping @Sendable () -> Adapter
    ) throws {
        let formatIdentifier = try Self.normalizedFormatIdentifier(Adapter.formatIdentifier)
        let registration = Registration(
            formatIdentifier: formatIdentifier,
            detectionBytePatterns: Adapter.detectionBytePatterns,
            makeAdapter: { makeAdapter() }
        )

        lock.lock()
        defer { lock.unlock() }
        if registrations[formatIdentifier] != nil {
            throw FormatAdapterRegistryError.duplicateRegistration(formatIdentifier: formatIdentifier)
        }
        registrations[formatIdentifier] = registration
        registrationOrder.append(formatIdentifier)
    }

    public func makeAdapter(formatIdentifier: String) throws -> any FormatAdapter {
        let normalized = try Self.normalizedFormatIdentifier(formatIdentifier)
        lock.lock()
        let registration = registrations[normalized]
        lock.unlock()
        guard let registration else {
            throw FormatAdapterRegistryError.unknownFormat(formatIdentifier: normalized)
        }
        return registration.makeAdapter()
    }

    public func adapter(detecting prefix: Data) -> (any FormatAdapter)? {
        lock.lock()
        let registrationsInOrder = registrationOrder.compactMap { registrations[$0] }
        lock.unlock()

        for registration in registrationsInOrder
        where registration.detectionBytePatterns.contains(where: { Self.prefix(prefix, matches: $0) }) {
            return registration.makeAdapter()
        }
        return nil
    }

    public func adapter(detecting url: URL, maxBytes: Int = 4096) throws -> (any FormatAdapter)? {
        let bytesToRead = min(maxPatternLength(), maxBytes)
        guard bytesToRead > 0 else { return nil }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: bytesToRead) ?? Data()
        return adapter(detecting: prefix)
    }

    public func registeredFormatIdentifiers() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(registrations.keys)
    }

    @discardableResult
    public func unregister(formatIdentifier: String) -> Bool {
        guard let normalized = try? Self.normalizedFormatIdentifier(formatIdentifier) else { return false }
        lock.lock()
        defer { lock.unlock() }
        let removed = registrations.removeValue(forKey: normalized) != nil
        if removed {
            registrationOrder.removeAll { $0 == normalized }
        }
        return removed
    }

    private func maxPatternLength() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return registrations.values
            .flatMap(\.detectionBytePatterns)
            .map(\.count)
            .max() ?? 0
    }

    private static func normalizedFormatIdentifier(_ id: String) throws -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else {
            throw FormatAdapterRegistryError.emptyFormatIdentifier
        }
        return trimmed
    }

    private static func prefix(_ bytes: Data, matches pattern: Data) -> Bool {
        !pattern.isEmpty
            && bytes.count >= pattern.count
            && bytes.prefix(pattern.count).elementsEqual(pattern)
    }
}
