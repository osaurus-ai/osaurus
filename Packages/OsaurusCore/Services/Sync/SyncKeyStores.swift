//
//  SyncKeyStores.swift
//  osaurus
//
//  Where the sync core keeps its device key, user secret and database key.
//

import Foundation
import OsaurusSync

enum SyncKeyStores {
    static let keychainService = OsaurusKeychainServices.sync

    /// The Keychain for shipped builds. Under `OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS`
    /// a file store beside the data directory, so an isolated live app keeps
    /// its identity across relaunches without touching the login Keychain.
    /// Unit tests get one in-memory store per data directory.
    static func make(dataDirectory: URL) -> KeyStore {
        if RuntimeEnvironment.isUnderTests {
            return memoryStore(for: dataDirectory)
        }
        if KeychainQueryHelpers.disablesKeychainForProcess {
            return FileKeyStore(directory: dataDirectory.deletingLastPathComponent()
                .appendingPathComponent("sync-keys", isDirectory: true))
        }
        return KeychainKeyStore(service: SpaceKeychainScope.service(keychainService), useDataProtectionKeychain: false)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var memoryStores: [String: MemoryKeyStore] = [:]

    private static func memoryStore(for dataDirectory: URL) -> MemoryKeyStore {
        lock.lock()
        defer { lock.unlock() }
        let key = dataDirectory.standardizedFileURL.path
        if let existing = memoryStores[key] { return existing }
        let store = MemoryKeyStore()
        memoryStores[key] = store
        return store
    }
}

/// One file per item, readable only by this user. For keychain-free test
/// builds only: the files are not encrypted.
final class FileKeyStore: KeyStore, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    func load(name: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        let url = try itemURL(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SyncError.KeyStore(code: SyncErrorCode.keyStore, detail: error.localizedDescription)
        }
    }

    func store(name: String, value: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let url = try itemURL(name)
            try value.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch let error as SyncError {
            throw error
        } catch {
            throw SyncError.KeyStore(code: SyncErrorCode.keyStore, detail: error.localizedDescription)
        }
    }

    func delete(name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = try itemURL(name)
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            throw SyncError.KeyStore(code: SyncErrorCode.keyStore, detail: error.localizedDescription)
        }
    }

    private func itemURL(_ name: String) throws -> URL {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw SyncError.InvalidInput(code: SyncErrorCode.invalidInput, detail: "bad key store item name")
        }
        return directory.appendingPathComponent(name)
    }
}
