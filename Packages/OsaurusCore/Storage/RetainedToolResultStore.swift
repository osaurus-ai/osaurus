import CryptoKit
import Foundation

/// Private, bounded recovery storage for the exact normalized result before
/// the registry applies its model-context cap. References confer no filesystem
/// access: both the session and agent must match, and ordinary tool permission
/// and exposure checks still precede file_read.
final class RetainedToolResultStore: @unchecked Sendable {
    struct Owner: Codable, Equatable, Sendable {
        let session: String
        let agent: UUID

        static var current: Self? {
            guard let session = ChatExecutionContext.currentSessionId,
                let agent = ChatExecutionContext.currentAgentId
            else { return nil }
            return Self(session: session, agent: agent)
        }
    }

    struct Reference: Sendable {
        let path: String
        let bytes: Int
        let sha256: String
        let lines: Int

        var payload: [String: Any] {
            [
                "path": path, "bytes": bytes, "sha256": sha256, "total_lines": lines,
                "format": "jsonl_text_chunks",
                "read": ["tool": "file_read", "arguments": ["path": path, "max_chars": 60_000]],
            ]
        }
    }

    struct Policy: Sendable {
        var entryBytes = 4 * 1024 * 1024
        var quotaBytes = 64 * 1024 * 1024
        var lifetime: TimeInterval = 24 * 60 * 60
    }

    private struct Record: Codable {
        let owner: Owner
        let sourceTool: String
        let created: Date
        let bytes: Int
        let sha256: String
        let lines: Int
        let storedBytes: Int
        let storedSHA256: String
    }

    enum StoreError: Error { case unavailable }

    static let scheme = "osaurus-tool-result://"
    static func current() -> RetainedToolResultStore {
        // Snapshot storage/test roots before detached I/O.
        let root = OsaurusPaths.cache().appendingPathComponent("tool-results", isDirectory: true)
        return RetainedToolResultStore(directory: { root })
    }

    /// The summary's short text clip must not hide the only way to recover
    /// omitted content. Preserve bounded recovery metadata before that clip;
    /// unrelated tool results retain their existing transcript representation.
    static func compactionContext(_ envelope: String) -> String? {
        guard envelope.contains(scheme),
            let root = try? JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any]
        else { return nil }
        let payload = root["result"] as? [String: Any] ?? root
        let candidates = [payload] + (payload["files"] as? [[String: Any]] ?? [])
        var references: [[String: Any]] = []
        for candidate in candidates {
            let metadata: [String: Any]
            if let retained = candidate["full_result"] as? [String: Any] {
                metadata = retained
            } else if candidate["kind"] as? String == "tool_result_page" {
                metadata = candidate
            } else {
                continue
            }
            guard let path = metadata["path"] as? String, path.hasPrefix(scheme),
                let id = UUID(uuidString: String(path.dropFirst(scheme.count))), scheme + id.uuidString == path
            else { continue }
            var kept: [String: Any] = ["path": path, "format": "jsonl_text_chunks"]
            for key in ["bytes", "source_bytes", "start_line", "end_line", "total_lines"] {
                if let number = metadata[key] as? Int, number >= 0 { kept[key] = number }
            }
            if let digest = metadata["sha256"] as? String, digest.count == 64,
                digest.allSatisfy({ $0.isHexDigit })
            {
                kept["sha256"] = digest
            }
            let next = metadata["next_read"] as? [String: Any]
            let nextArguments = next?["arguments"] as? [String: Any]
            let start = max(1, nextArguments?["start_line"] as? Int ?? 1)
            kept["read"] = [
                "tool": "file_read",
                "arguments": [
                    "path": path, "start_line": start, "max_chars": 60_000,
                ],
            ]
            references.append(kept)
        }
        guard !references.isEmpty,
            let data = try? JSONSerialization.data(
                withJSONObject: ["retained_results": references],
                options: [.sortedKeys]
            ),
            data.count <= 16_384
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static let ioLock = NSLock()
    private let lock = RetainedToolResultStore.ioLock
    private let directory: @Sendable () -> URL
    private let now: @Sendable () -> Date
    private let policy: Policy

    init(
        directory: @escaping @Sendable () -> URL,
        policy: Policy = Policy(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.policy = policy
        self.now = now
    }

    func retain(_ text: String, tool: String, owner: Owner) throws -> Reference {
        try lock.withLock {
            try Task.checkCancellation()
            guard text.utf8.count <= policy.entryBytes else { throw StoreError.unavailable }
            let root = directory()
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw StoreError.unavailable
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            // JSONL preserves every scalar, including embedded newlines, without
            // making a single-line JSON/HTML result impossible to line-page.
            let input = Array(text.utf8)
            var output = Data()
            var start = 0
            var count = 0
            while start < input.count {
                try Task.checkCancellation()
                var end = min(start + 1024, input.count)
                while end < input.count, input[end] & 0xc0 == 0x80 { end -= 1 }
                let chunk = String(decoding: input[start ..< end], as: UTF8.self)
                output.append(
                    try JSONSerialization.data(
                        withJSONObject: ["start_byte": start, "end_byte_exclusive": end, "text": chunk],
                        options: [.sortedKeys, .withoutEscapingSlashes]
                    )
                )
                output.append(10)
                count += 1
                start = end
            }
            let digest = SHA256.hash(data: Data(input)).map { String(format: "%02x", $0) }.joined()
            let record = Record(
                owner: owner,
                sourceTool: tool,
                created: now(),
                bytes: input.count,
                sha256: digest,
                lines: count,
                storedBytes: output.count,
                storedSHA256: SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined()
            )
            let metadata = try JSONEncoder().encode(record)
            guard metadata.count < 16_384 else { throw StoreError.unavailable }
            try makeRoom(in: root, required: output.count + metadata.count)
            let id = UUID().uuidString
            let dataURL = root.appendingPathComponent(id + ".jsonl")
            let metadataURL = root.appendingPathComponent(id + ".json")
            do {
                try output.write(to: dataURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dataURL.path)
                try metadata.write(to: metadataURL, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
            } catch {
                try? FileManager.default.removeItem(at: dataURL)
                try? FileManager.default.removeItem(at: metadataURL)
                throw error
            }
            return Reference(path: Self.scheme + id, bytes: input.count, sha256: digest, lines: count)
        }
    }

    /// These line numbers address JSONL chunks, not the fetched document's
    /// original lines. Concatenating the `text` fields reconstructs the exact
    /// pre-cap normalized result; byte ranges and SHA identify that source.
    func read(path: String, owner: Owner?, arguments: [String: Any]) -> String {
        lock.withLock {
            do {
                guard let owner, path.hasPrefix(Self.scheme),
                    let id = UUID(uuidString: String(path.dropFirst(Self.scheme.count))),
                    Self.scheme + id.uuidString == path
                else { throw StoreError.unavailable }
                let root = directory()
                guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw StoreError.unavailable
                }
                let metadataURL = root.appendingPathComponent(id.uuidString + ".json")
                let dataURL = root.appendingPathComponent(id.uuidString + ".jsonl")
                for (url, ceiling) in [(metadataURL, 16_384), (dataURL, policy.quotaBytes)] {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                        (values.fileSize ?? Int.max) <= ceiling
                    else { throw StoreError.unavailable }
                }
                let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: metadataURL))
                guard record.owner == owner, now().timeIntervalSince(record.created) <= policy.lifetime,
                    record.bytes >= 0, record.bytes <= policy.entryBytes,
                    record.storedBytes >= 0, record.storedBytes <= policy.quotaBytes
                else { throw StoreError.unavailable }
                let data = try Data(contentsOf: dataURL, options: [.mappedIfSafe])
                guard data.count == record.storedBytes,
                    SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == record.storedSHA256
                else { throw StoreError.unavailable }
                let lines = String(decoding: data, as: UTF8.self).split(
                    separator: "\n",
                    omittingEmptySubsequences: true
                )
                guard lines.count == record.lines else { throw StoreError.unavailable }
                if let mode = arguments["mode"] as? String, !mode.isEmpty, mode.lowercased() != "text" {
                    return ToolEnvelope.failure(
                        kind: .invalidArgs, message: "Retained results support text paging, not document structure mode.",
                        field: "mode", tool: "file_read", retryable: false
                    )
                }
                let tail = max(0, ArgumentCoercion.int(arguments["tail_lines"]) ?? 0)
                let start = tail > 0 ? max(1, record.lines - tail + 1)
                    : max(1, ArgumentCoercion.int(arguments["start_line"]) ?? 1)
                let requestedEnd = tail > 0 ? record.lines : ArgumentCoercion.int(arguments["end_line"]) ?? record.lines
                let end = requestedEnd > 0 ? min(requestedEnd, record.lines) : record.lines
                guard start <= end else {
                    return ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "Choose a start_line between 1 and \(record.lines).",
                        field: "start_line",
                        tool: "file_read",
                        retryable: false
                    )
                }
                let limit = min(60_000, max(1, ArgumentCoercion.int(arguments["max_chars"]) ?? 15_000))
                var kept: [String] = []
                var result = ""
                for index in (start - 1) ..< end {
                    try Task.checkCancellation()
                    let candidate = kept + [String(lines[index])]
                    let next = index + 2
                    var payload: [String: Any] = [
                        "kind": "tool_result_page", "path": path, "source_tool": record.sourceTool,
                        "format": "jsonl_text_chunks", "source_bytes": record.bytes, "sha256": record.sha256,
                        "start_line": start, "end_line": index + 1, "total_lines": record.lines,
                        "content": candidate.joined(separator: "\n"), "has_more": next <= record.lines,
                        "truncated": next <= record.lines,
                    ]
                    if next <= record.lines {
                        payload["next_read"] = [
                            "tool": "file_read",
                            "arguments": [
                                "path": path, "start_line": next, "max_chars": limit,
                            ],
                        ]
                    }
                    let warnings: [String]? = next <= record.lines ? [
                        "Partial saved result: only JSONL chunks \(start)–\(index + 1) of \(record.lines) are included. "
                            + "Later chunks are omitted from this page. Continue with next_read to read the remaining "
                            + "saved content; the original tool call does not need to be repeated."
                    ] : nil
                    let encoded = ToolEnvelope.success(tool: "file_read", result: payload, warnings: warnings)
                    if encoded.utf8.count > limit {
                        if kept.isEmpty {
                            return ToolEnvelope.failure(
                                kind: .invalidArgs,
                                message:
                                    "max_chars is too small for one retained-result chunk; use at least \(encoded.utf8.count).",
                                field: "max_chars",
                                tool: "file_read",
                                retryable: false
                            )
                        }
                        break
                    }
                    kept = candidate
                    result = encoded
                }
                guard !result.isEmpty else { throw StoreError.unavailable }
                return result
            } catch {
                // Identical response for an expired, missing, corrupt, forged or
                // differently owned reference; never disclose another owner.
                return ToolEnvelope.failure(
                    kind: .notFound,
                    message:
                        "Retained tool result is unavailable or expired for this session. Fetch a bounded fresh result.",
                    tool: "file_read",
                    retryable: false
                )
            }
        }
    }

    private func makeRoom(in root: URL, required: Int) throws {
        guard required <= policy.quotaBytes else { throw StoreError.unavailable }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys))
        var groups: [String: [URL]] = [:]
        var used = 0
        for url in urls {
            let values = try url.resourceValues(forKeys: keys)
            let (sum, overflow) = used.addingReportingOverflow(max(0, values.fileSize ?? 0))
            guard !overflow else { throw StoreError.unavailable }
            used = sum
            let stem = url.deletingPathExtension().lastPathComponent
            if ["json", "jsonl"].contains(url.pathExtension), UUID(uuidString: stem) != nil {
                groups[stem, default: []].append(url)
            }
        }
        // Orphaned payloads from an interrupted write count against quota too.
        // Unknown files count but are never removed; a full cache then refuses
        // retention rather than growing or deleting unrelated data.
        var entries: [(files: [URL], created: Date, bytes: Int)] = []
        for files in groups.values {
            var created = Date.distantPast
            var size = 0
            for url in files {
                let values = try url.resourceValues(forKeys: keys)
                size += max(0, values.fileSize ?? 0)
                created = max(created, values.contentModificationDate ?? .distantPast)
            }
            if let metadata = files.first(where: { $0.pathExtension == "json" }),
                let values = try? metadata.resourceValues(forKeys: keys),
                values.isRegularFile == true, values.isSymbolicLink != true,
                (values.fileSize ?? Int.max) < 16_384,
                let bytes = try? Data(contentsOf: metadata),
                let record = try? JSONDecoder().decode(Record.self, from: bytes)
            {
                created = record.created
            }
            entries.append((files, created, size))
        }
        entries.sort { $0.created < $1.created }
        for entry in entries {
            guard now().timeIntervalSince(entry.created) > policy.lifetime || used > policy.quotaBytes - required else {
                continue
            }
            for url in entry.files { try FileManager.default.removeItem(at: url) }
            used -= entry.bytes
        }
        guard used <= policy.quotaBytes - required else { throw StoreError.unavailable }
    }
}
