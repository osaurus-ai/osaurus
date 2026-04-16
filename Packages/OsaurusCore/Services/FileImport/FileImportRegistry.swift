//
//  FileImportRegistry.swift
//  osaurus
//
//  Central registry for built-in and plugin-provided file importers.
//

import Foundation
import UniformTypeIdentifiers

protocol FileImporter: Sendable {
    var descriptor: FileImportDescriptor { get }
    func importFile(at url: URL) async throws -> [Attachment]
}

final class FileImportRegistry: @unchecked Sendable {
    static let shared = FileImportRegistry()

    private struct Entry: Sendable {
        let importer: any FileImporter
        let ownerPluginId: String?
        let registrationOrder: Int
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextRegistrationOrder = 0

    init() {}

    func register(_ importer: any FileImporter, ownerPluginId: String? = nil) {
        lock.withLock {
            entries.removeAll { $0.importer.descriptor.id == importer.descriptor.id }
            entries.append(
                Entry(
                    importer: importer,
                    ownerPluginId: ownerPluginId,
                    registrationOrder: nextRegistrationOrder
                )
            )
            nextRegistrationOrder += 1
        }
    }

    func unregisterImporter(id: String) {
        lock.withLock {
            entries.removeAll { $0.importer.descriptor.id == id }
        }
    }

    func unregisterPluginImporters(pluginId: String) {
        lock.withLock {
            entries.removeAll { $0.ownerPluginId == pluginId }
        }
    }

    func importer(for url: URL) -> (any FileImporter)? {
        lock.withLock {
            resolveLocked(for: url)?.importer
        }
    }

    func descriptor(for url: URL) -> FileImportDescriptor? {
        lock.withLock {
            resolveLocked(for: url)?.importer.descriptor
        }
    }

    func descriptors() -> [FileImportDescriptor] {
        lock.withLock {
            entries
                .sorted { lhs, rhs in
                    let lhsPriority = sourcePriority(lhs.importer.descriptor.source)
                    let rhsPriority = sourcePriority(rhs.importer.descriptor.source)
                    if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                    return lhs.registrationOrder < rhs.registrationOrder
                }
                .map(\.importer.descriptor)
        }
    }

    func supportedDocumentTypes() -> [UTType] {
        var seen = Set<String>()
        var results: [UTType] = []

        for descriptor in descriptors() {
            for type in descriptor.supportedUTTypes where seen.insert(type.identifier).inserted {
                results.append(type)
            }
        }

        return results
    }

    func canImport(url: URL) -> Bool {
        descriptor(for: url) != nil
    }

    func reset() {
        lock.withLock {
            entries.removeAll()
            nextRegistrationOrder = 0
        }
    }

    private func resolveLocked(for url: URL) -> Entry? {
        entries
            .filter { $0.importer.descriptor.matches(url: url) }
            .sorted { lhs, rhs in
                let lhsPriority = sourcePriority(lhs.importer.descriptor.source)
                let rhsPriority = sourcePriority(rhs.importer.descriptor.source)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return lhs.registrationOrder < rhs.registrationOrder
            }
            .first
    }

    private func sourcePriority(_ source: FileImportSource) -> Int {
        switch source {
        case .core:
            return 0
        case .nativePlugin:
            return 1
        case .sandboxPlugin:
            return 2
        }
    }
}
