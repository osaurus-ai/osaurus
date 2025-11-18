//
//  FileReadTool.swift
//  osaurus
//
//  Implements file.read tool: unrestricted path access with optional byte range and encoding.
//

import Foundation

struct FileReadTool: ChatTool {
    let name: String = "file.read"
    let toolDescription: String =
        "Read file contents from disk. Supports start/max_bytes window and utf8/base64 encoding. Returns a summary plus JSON payload."

    var parameters: JSONValue? {
        return .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Target file path. Supports ~ expansion."),
                ]),
                "start": .object([
                    "type": .string("integer"),
                    "description": .string("Byte offset to begin reading (>= 0). Defaults to 0."),
                ]),
                "max_bytes": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum number of bytes to read. Omit to read to EOF."),
                ]),
                "encoding": .object([
                    "type": .string("string"),
                    "enum": .array([.string("utf8"), .string("base64")]),
                    "description": .string(
                        "Output encoding for content. Defaults to utf8; falls back to base64 on decode failure."
                    ),
                ]),
                "with_stats": .object([
                    "type": .string("boolean"),
                    "description": .string("Include file size and modification time in payload."),
                ]),
            ]),
            "required": .array([.string("path")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let rawArgs =
            (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]
        let expandedPath = Self.resolvePath((rawArgs["path"] as? String) ?? "")
        guard !expandedPath.isEmpty else {
            return Self.failureResult(reason: "Missing or empty path", path: nil)
        }
        let url = URL(fileURLWithPath: expandedPath).standardizedFileURL

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return Self.failureResult(reason: "File does not exist", path: url.path)
        }
        guard !isDir.boolValue else {
            return Self.failureResult(reason: "Path is a directory", path: url.path)
        }

        let start = max(0, (rawArgs["start"] as? Int) ?? 0)
        let maxBytesArg = (rawArgs["max_bytes"] as? Int)
        let withStats = (rawArgs["with_stats"] as? Bool) ?? false
        let requestedEncoding = ((rawArgs["encoding"] as? String) ?? "utf8").lowercased()
        let encoding = (requestedEncoding == "base64") ? "base64" : "utf8"

        // Obtain file size and mod time (optional)
        let attrs = (try? fm.attributesOfItem(atPath: url.path)) ?? [:]
        let fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attrs[.modificationDate] as? Date)

        // Read bytes within range
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            if start > 0 {
                try handle.seek(toOffset: UInt64(start))
            }
            if let maxBytes = maxBytesArg, maxBytes >= 0 {
                data = try handle.read(upToCount: max(0, maxBytes)) ?? Data()
            } else {
                data = try handle.readToEnd() ?? Data()
            }
        } catch {
            return Self.failureResult(reason: "Read error: \(error.localizedDescription)", path: url.path)
        }

        // Determine if truncated
        let totalRemaining =
            (fileSize >= 0) ? max(Int64(0), fileSize - Int64(start)) : Int64(-1)
        let truncated: Bool = {
            if let maxBytes = maxBytesArg, totalRemaining >= 0 {
                return Int64(max(0, maxBytes)) < totalRemaining
            }
            return false
        }()

        // Encode content
        let encodingUsed: String
        let contentString: String
        if encoding == "base64" {
            encodingUsed = "base64"
            contentString = data.base64EncodedString()
        } else {
            if let s = String(data: data, encoding: .utf8) {
                encodingUsed = "utf8"
                contentString = s
            } else {
                encodingUsed = "base64"
                contentString = data.base64EncodedString()
            }
        }

        // Build payload
        var payload: [String: Any] = [
            "pathResolved": url.path,
            "start": start,
            "readBytes": data.count,
            "truncated": truncated,
            "encodingUsed": encodingUsed,
            "content": contentString,
        ]
        if withStats {
            if fileSize >= 0 { payload["size"] = fileSize }
            if let m = mtime {
                let iso = ISO8601DateFormatter()
                payload["modifiedAt"] = iso.string(from: m)
            }
        }

        let summary =
            "Read \(data.count) bytes from \(url.path)\(truncated ? " (truncated)" : "") (\(encodingUsed))"
        let json =
            (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return summary + "\n" + json
    }

    // MARK: - Helpers
    private static func resolvePath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        if path.hasPrefix("~") {
            let home = NSHomeDirectory()
            if path == "~" { return home }
            let idx = path.index(after: path.startIndex)
            return home + String(path[idx...])
        }
        return path
    }

    private static func failureResult(reason: String, path: String?) -> String {
        let summary = "File read failed: \(reason)"
        var dict: [String: Any] = ["error": reason]
        if let p = path { dict["path"] = p }
        let data =
            (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return summary + "\n" + json
    }
}
