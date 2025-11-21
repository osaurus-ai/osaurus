//
//  FileWriteTool.swift
//  osaurus
//
//  Implements file.write tool: explicit overwrite/append flags; optional directory creation.
//

import Foundation

struct FileWriteTool: OsaurusTool {
    let name: String = "file_write"
    let description: String =
        "Write content to a file. Requires explicit overwrite or append when target exists. Supports utf8/base64 and optional directory creation."

    var parameters: JSONValue? {
        return .object([
            "type": .string("object"),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Target file path. Supports ~ expansion."),
                ]),
                "content": .object([
                    "type": .string("string"),
                    "description": .string("Content to write, interpreted using the specified encoding."),
                ]),
                "encoding": .object([
                    "type": .string("string"),
                    "enum": .array([.string("utf8"), .string("base64")]),
                    "description": .string("Input encoding of content. Defaults to utf8."),
                ]),
                "overwrite": .object([
                    "type": .string("boolean"),
                    "description": .string("Overwrite existing file (exclusive with append)."),
                ]),
                "append": .object([
                    "type": .string("boolean"),
                    "description": .string("Append to file (exclusive with overwrite). Creates file if missing."),
                ]),
                "create_dirs": .object([
                    "type": .string("boolean"),
                    "description": .string("Create parent directories if they don't exist."),
                ]),
            ]),
            "required": .array([.string("path"), .string("content")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let args =
            (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8)) as? [String: Any]) ?? [:]

        let expandedPath = Self.resolvePath((args["path"] as? String) ?? "")
        guard !expandedPath.isEmpty else {
            return Self.failureResult(reason: "Missing or empty path", path: nil)
        }
        let url = URL(fileURLWithPath: expandedPath).standardizedFileURL

        // Flags and inputs
        let contentRaw = (args["content"] as? String) ?? ""
        guard !contentRaw.isEmpty else {
            return Self.failureResult(reason: "Missing content", path: url.path)
        }
        let requestedEncoding = ((args["encoding"] as? String) ?? "utf8").lowercased()
        let encoding = (requestedEncoding == "base64") ? "base64" : "utf8"
        let overwrite = (args["overwrite"] as? Bool) ?? false
        let append = (args["append"] as? Bool) ?? false
        let createDirs = (args["create_dirs"] as? Bool) ?? false

        if overwrite && append {
            return Self.failureResult(reason: "Flags conflict: cannot set both overwrite and append", path: url.path)
        }

        // Decode content
        let data: Data
        if encoding == "base64" {
            guard let decoded = Data(base64Encoded: contentRaw) else {
                return Self.failureResult(reason: "Invalid base64 content", path: url.path)
            }
            data = decoded
        } else {
            guard let d = contentRaw.data(using: .utf8) else {
                return Self.failureResult(reason: "Invalid UTF-8 content", path: url.path)
            }
            data = d
        }

        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        var createdDirectories = false

        // Ensure directory
        if !fm.fileExists(atPath: parent.path) {
            if createDirs {
                do {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    createdDirectories = true
                } catch {
                    return Self.failureResult(
                        reason: "Failed to create directories: \(error.localizedDescription)",
                        path: url.path
                    )
                }
            } else {
                return Self.failureResult(reason: "Parent directory does not exist", path: url.path)
            }
        }

        // Disallow writing to directory paths
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return Self.failureResult(reason: "Path is a directory", path: url.path)
        }

        let exists = fm.fileExists(atPath: url.path)
        var operation = "created"
        var bytesWritten = 0

        if exists {
            if !overwrite && !append {
                return Self.failureResult(
                    reason: "File exists; specify overwrite=true or append=true",
                    path: url.path
                )
            }
            if append {
                do {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    bytesWritten = data.count
                    operation = "appended"
                } catch {
                    return Self.failureResult(reason: "Append failed: \(error.localizedDescription)", path: url.path)
                }
            } else if overwrite {
                do {
                    try data.write(to: url, options: [.atomic])
                    bytesWritten = data.count
                    operation = "overwritten"
                } catch {
                    return Self.failureResult(reason: "Overwrite failed: \(error.localizedDescription)", path: url.path)
                }
            }
        } else {
            // Create new file
            do {
                // For "append" on new file, we simply create with full content
                try data.write(to: url, options: [.atomic])
                bytesWritten = data.count
                operation = "created"
            } catch {
                return Self.failureResult(reason: "Create failed: \(error.localizedDescription)", path: url.path)
            }
        }

        let payload: [String: Any] = [
            "pathResolved": url.path,
            "bytesWritten": bytesWritten,
            "operation": operation,
            "createdDirectories": createdDirectories,
            "encodingUsed": encoding,
        ]
        let json =
            (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let summary = "Wrote \(bytesWritten) bytes to \(url.path) (\(operation))"
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
        let summary = "File write failed: \(reason)"
        var dict: [String: Any] = ["error": reason]
        if let p = path { dict["path"] = p }
        let data =
            (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        return summary + "\n" + json
    }
}
