//
//  AttentionFileIO.swift
//  osaurus
//
//  Small JSON files the attention layer keeps under `~/.osaurus`: written
//  atomically and readable only by the owner (0600). A file that fails to
//  decode is moved aside (`<name>.corrupt-<timestamp>`) rather than read as
//  empty and overwritten, so nothing is lost silently.
//

import Foundation

enum AttentionFileIO {
    enum ReadResult<Value> {
        case missing
        case loaded(Value)
        /// The file existed but did not decode; it was moved to `quarantined`.
        case corrupt(quarantined: URL?)
    }

    static func read<Value: Decodable>(
        _ type: Value.Type, from url: URL, decoder: JSONDecoder = JSONDecoder()
    ) -> ReadResult<Value> {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else {
            // Unreadable right now (permissions, I/O): leave it in place.
            AttentionLog.error("\(url.lastPathComponent) unreadable; left in place")
            return .corrupt(quarantined: nil)
        }
        do {
            return .loaded(try decoder.decode(Value.self, from: data))
        } catch {
            let moved = quarantine(url)
            AttentionLog.error("\(url.lastPathComponent) did not decode; moved aside")
            return .corrupt(quarantined: moved)
        }
    }

    /// Writes `value` atomically with owner-only permissions.
    @discardableResult
    static func write<Value: Encodable>(
        _ value: Value, to url: URL, encoder: JSONEncoder = JSONEncoder()
    ) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            AttentionLog.error("\(url.lastPathComponent) save failed: \(error.localizedDescription)")
            return false
        }
    }

    static func quarantine(_ url: URL) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        do {
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            return nil
        }
    }
}
