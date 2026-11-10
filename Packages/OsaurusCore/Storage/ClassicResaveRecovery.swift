//
//  ClassicResaveRecovery.swift
//  osaurus
//
//  Osaurus Classic (0.25.x) shares `~/.osaurus` and rewrites some JSON
//  records without the fields it doesn't know. A guarded store hands this
//  type every record it writes; the bytes are copied under
//  `OsaurusPaths.classicResaveCopies()`. On read, a listed field that the
//  record lacks but the copy has is put back. Every other field comes from
//  the record, so edits made in Classic still win.
//

import Foundation

enum ClassicResaveRecovery {
    /// Object keys from the record's root to one field Classic doesn't know.
    typealias FieldPath = [String]

    /// Call before writing `data` to `url`: a copy older than the record
    /// could put back a field the user has since cleared.
    static func recordWrite(_ data: Data, to url: URL) {
        guard let copy = copyURL(for: url) else { return }
        do {
            try FileManager.default.createDirectory(
                at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: copy, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to keep a Classic resave copy of \(url.lastPathComponent): \(error)")
        }
    }

    /// `data` with every field in `fields` that it lacks taken from the
    /// copy of the record at `url`. Returns `data` unchanged when nothing
    /// is missing or there is no copy.
    static func restoring(_ data: Data, at url: URL, fields: [FieldPath]) -> Data {
        guard !fields.isEmpty,
            let copyURL = copyURL(for: url),
            let copyData = try? Data(contentsOf: copyURL),
            var record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let copy = (try? JSONSerialization.jsonObject(with: copyData)) as? [String: Any]
        else { return data }

        var restoredAny = false
        for path in fields where restore(path[...], into: &record, from: copy) {
            restoredAny = true
        }
        guard restoredAny,
            let merged = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        else { return data }
        return merged
    }

    /// Drop the copy of a deleted record.
    static func forget(_ url: URL) {
        guard let copy = copyURL(for: url) else { return }
        try? FileManager.default.removeItem(at: copy)
    }

    /// Where the copy of `url` lives, or nil for files outside the data root.
    static func copyURL(for url: URL) -> URL? {
        let rootPath = OsaurusPaths.root().standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(path.dropFirst(rootPath.count + 1))
        return OsaurusPaths.classicResaveCopies().appendingPathComponent(relative)
    }

    private static func restore(
        _ path: ArraySlice<String>,
        into record: inout [String: Any],
        from copy: [String: Any]
    ) -> Bool {
        guard let key = path.first, let copyValue = copy[key] else { return false }
        if path.count == 1 {
            guard record[key] == nil else { return false }
            record[key] = copyValue
            return true
        }
        // A parent object missing from the record was removed on purpose;
        // only fields inside objects the record still has are put back.
        guard var child = record[key] as? [String: Any], let copyChild = copyValue as? [String: Any]
        else { return false }
        guard restore(path.dropFirst(), into: &child, from: copyChild) else { return false }
        record[key] = child
        return true
    }
}
