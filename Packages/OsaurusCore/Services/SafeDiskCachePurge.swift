import Foundation
import SQLite3

/// Deletes indexed cache payloads only. The caller serializes against runtime
/// cache IO. Unknown files and incomplete/unindexed writes are never swept.
enum SafeDiskCachePurge {
    struct Result: Sendable {
        var reclaimedBytes = 0
        var removedFiles = 0
        var error: String?
    }

    static func clear(directory: URL) -> Result {
        var result = Result()
        var db: OpaquePointer?
        let fm = FileManager.default
        do {
            let root = directory.standardizedFileURL
            guard root.pathComponents.count > 2,
                root.resolvingSymlinksInPath().path == root.path,
                !fm.fileExists(atPath: root.appendingPathComponent("config.json").path),
                !fm.fileExists(atPath: root.appendingPathComponent("jang_config.json").path)
            else { throw failure("Refusing to clear an ambiguous cache directory or model bundle.") }
            guard fm.fileExists(atPath: root.path) else { return result }
            let index = root.appendingPathComponent("cache_index.db")
            guard fm.fileExists(atPath: index.path) else {
                throw failure("No cache index found. Unrecognized files were left untouched.")
            }
            guard try index.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
            else { throw failure("Refusing a linked cache index.") }
            guard sqlite3_open_v2(index.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
            else { throw failure("Cannot open the cache index.") }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 1000)
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK
            else { throw failure("Cache is busy. Try again after current work finishes.") }
            var committed = false
            defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT hash FROM cache_entries", -1, &statement, nil) == SQLITE_OK
            else { throw failure("Unrecognized cache index. Nothing was cleared.") }
            var hashes = Set<String>()
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
                    sqlite3_finalize(statement)
                    throw failure("Cannot read cache ownership records.")
                }
                let hash = String(cString: text)
                guard hash.count == 32, hash.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                    sqlite3_finalize(statement)
                    throw failure("Invalid cache ownership record. Nothing was cleared.")
                }
                hashes.insert(hash)
            }
            sqlite3_finalize(statement)
            var targets = hashes.map { root.appendingPathComponent("\($0).safetensors") }
            // Companion ownership comes from its explicit linked KV hash, not
            // from a broad ssm-* filename glob.
            var companionRoots = [root]
            let companionRoot = root.appendingPathComponent("ssm_companion")
            if fm.fileExists(atPath: companionRoot.path) {
                let values = try companionRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isDirectory == true else {
                    throw failure("Refusing a linked or invalid companion cache directory.")
                }
                companionRoots.append(companionRoot)
            }
            let companionFiles = try companionRoots.flatMap {
                try fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isSymbolicLinkKey])
            }
            for url in companionFiles {
                let name = url.lastPathComponent
                guard name.hasPrefix("ssm-"), name.hasSuffix(".json"),
                    name.count == 4 + 64 + 5 || name.count == 4 + 32 + 5,
                    try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                    let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                    fileSize < 1_048_576,
                    let bytes = try? Data(contentsOf: url), bytes.count < 1_048_576,
                    let metadata = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                    let kvHash = metadata["kv_hash"] as? String, hashes.contains(kvHash),
                    metadata["num_states"] is NSNumber
                else { continue }
                let stem = String(name.dropLast(5))
                guard stem.dropFirst(4).allSatisfy({ "0123456789abcdef".contains($0) }) else { continue }
                targets.append(url)
                targets.append(url.deletingLastPathComponent().appendingPathComponent(stem + ".safetensors"))
            }
            // Validate every target before deleting any. Never follow a link.
            for url in targets where fm.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
                guard values.isSymbolicLink != true, values.isRegularFile == true else {
                    throw failure("A cache payload is linked or not a regular file. Nothing was cleared.")
                }
            }
            for url in targets where fm.fileExists(atPath: url.path) {
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                try fm.removeItem(at: url)
                result.reclaimedBytes += size
                result.removedFiles += 1
            }
            guard sqlite3_exec(db, "DELETE FROM cache_entries", nil, nil, nil) == SQLITE_OK,
                sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK
            else { throw failure("Cache index update failed; some payloads may already have been removed.") }
            committed = true
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "SafeDiskCachePurge", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
