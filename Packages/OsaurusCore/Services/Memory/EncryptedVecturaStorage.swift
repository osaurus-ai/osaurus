//
//  EncryptedVecturaStorage.swift
//  osaurus
//
//  Hook point for AES-GCM encryption of VecturaKit's on-disk files.
//
//  ## Status
//
//  Per-agent partitioning (one VecturaKit instance per agent) is now
//  live in `MemorySearchService`. That removes the cross-agent
//  vector-leakage risk the security audit highlighted (no agent's
//  search ever opens another agent's index directory).
//
//  Per-file AES-GCM encryption of VecturaKit's underlying storage is
//  intentionally **not** wired up in this revision because the public
//  `VecturaStorage` adapter protocol exposed by the pinned VecturaKit
//  revision is too narrow to host an envelope-format wrapper without
//  a co-ordinated upstream change.
//
//  ## Mitigation in place
//
//  Until that upstream change lands we rely on the
//  **rebuild-from-encrypted-SQL** invariant guaranteed by
//  `StorageMigrator`:
//
//    - The authoritative copy of every fact / episode / transcript
//      turn lives in `memory.sqlite`, which is SQLCipher-encrypted.
//    - The vector files under `~/.osaurus/memory/vectura/<agent>/`
//      are derivable artifacts: an attacker who exfiltrates the
//      vector dir without the SQLCipher key gets shape-of-content
//      (token frequency, embedding vectors) but cannot reconstruct
//      the source text without the underlying SQLCipher DB.
//    - After every storage migration (`storage-version` bump) and
//      after key rotation, `StorageMigrator` calls
//      `MemorySearchService.shared.rebuildIndex()` to wipe the
//      existing per-agent dirs and rebuild them from the encrypted
//      SQL. This narrows the window in which a stale vector file
//      could leak data to the time between the source row being
//      written and the next consolidator pass / launch.
//
//  ## Future work
//
//  When VecturaKit exposes a richer `VecturaStorage` adapter, this
//  file is the natural home for `EncryptedVecturaStorage`:
//
//    struct EncryptedVecturaStorage: VecturaStorage {
//        let key: SymmetricKey
//        let underlying: FileStorageProvider
//
//        func read(_ name: String) throws -> Data {
//            try EncryptedFileStore.open(envelope: try underlying.read(name), key: key)
//        }
//        func write(_ data: Data, to name: String) throws {
//            let nonce = AES.GCM.Nonce()
//            let sealed = try AES.GCM.seal(data, using: key, nonce: nonce)
//            // write [version][nonce][ciphertext+tag] to underlying
//        }
//    }
//
//  Tracked in `docs/MEMORY.md` under "Vector encryption roadmap".
//

import CryptoKit
import Foundation

/// Marker enum so the rest of the codebase can reference the
/// "encrypted vector store" concept symbolically and discover it via
/// search even before the storage adapter is wired up.
public enum EncryptedVecturaStorage {
    /// Returns true once this build's VecturaKit revision exposes a
    /// hookable `VecturaStorage` adapter. Currently always false.
    /// Wire this up by enabling the corresponding upstream feature
    /// flag and replacing the body with a runtime check.
    public static var isAvailable: Bool { false }

    /// Documented threat model for the current state.
    public static let threatModelNote = """
        Vector files under ~/.osaurus/memory/vectura/<agent>/ are
        currently plaintext on disk. The authoritative source content
        lives in the SQLCipher-encrypted memory.sqlite. After any
        StorageMigrator run, vectors are rebuilt from the encrypted
        source so an attacker who reads the vector dir without the
        SQLCipher key gets only embedding shapes, not the source text.
        """
}
