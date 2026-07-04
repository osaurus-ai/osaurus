//
//  SkillImportPolicy.swift
//  osaurus
//
//  Guardrails for importing third-party skill archives before they enter the
//  persisted skill store.
//

import Darwin
import Foundation

/// Import limits for a third-party skill bundle. The defaults are intentionally
/// generous for normal skill packs while still bounding the user-clicked ZIP
/// path before extraction and again before persistence.
public struct SkillImportPolicy: Sendable, Equatable {
    public static let `default` = SkillImportPolicy()

    public let maxArchiveBytes: Int64
    public let maxEntryBytes: Int64
    public let maxEntryCount: Int
    public let maxPathDepth: Int

    public init(
        maxArchiveBytes: Int64 = 50 * 1024 * 1024,
        maxEntryBytes: Int64 = 10 * 1024 * 1024,
        maxEntryCount: Int = 512,
        maxPathDepth: Int = 16
    ) {
        self.maxArchiveBytes = maxArchiveBytes
        self.maxEntryBytes = maxEntryBytes
        self.maxEntryCount = maxEntryCount
        self.maxPathDepth = maxPathDepth
    }

    public func validateArchiveBeforeExtraction(_ zipURL: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: zipURL.path)
        let archiveBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard archiveBytes <= maxArchiveBytes else {
            throw SkillFileError.archiveTooLarge(limitBytes: maxArchiveBytes)
        }

        let entries = try Self.listArchiveEntries(in: zipURL)
        try validateArchiveEntries(entries)
    }

    func validateArchiveEntries(_ entries: [SkillArchiveEntry]) throws {
        guard entries.count <= maxEntryCount else {
            throw SkillFileError.archiveEntryLimitExceeded(limit: maxEntryCount)
        }

        for entry in entries {
            try validateArchivePath(entry.name)
            if !entry.isDirectory, entry.uncompressedSize > maxEntryBytes {
                throw SkillFileError.archiveEntryTooLarge(path: entry.name, limitBytes: maxEntryBytes)
            }
        }
    }

    func validateArchiveEntryNames(_ names: [String]) throws {
        try validateArchiveEntries(names.map { SkillArchiveEntry(name: $0, uncompressedSize: 0) })
    }

    public func scanExtractedTree(at rootURL: URL) throws -> SkillImportPlan {
        let fileManager = FileManager.default
        let root = rootURL.standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var fileCount = 0
        var skillMarkdowns: [String] = []

        guard
            let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        else {
            throw SkillFileError.invalidSkillArchive
        }

        for case let entry as URL in enumerator {
            let relativePath = try relativePath(for: entry, in: root)
            try validateArchivePath(relativePath)

            let values = try entry.resourceValues(
                forKeys: [.fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw SkillFileError.archiveEntryUnsupported(path: relativePath)
            }

            let resolvedEntry = entry.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isContained(resolvedEntry, in: resolvedRoot) else {
                throw SkillFileError.archiveEntryEscapes(path: relativePath)
            }

            if values.isDirectory == true {
                continue
            }

            guard values.isRegularFile == true else {
                throw SkillFileError.archiveEntryUnsupported(path: relativePath)
            }

            fileCount += 1
            guard fileCount <= maxEntryCount else {
                throw SkillFileError.archiveEntryLimitExceeded(limit: maxEntryCount)
            }

            let fileSize = Int64(values.fileSize ?? 0)
            guard fileSize <= maxEntryBytes else {
                throw SkillFileError.archiveEntryTooLarge(path: relativePath, limitBytes: maxEntryBytes)
            }

            if entry.lastPathComponent == "SKILL.md" {
                skillMarkdowns.append(relativePath)
            }
        }

        guard let selected = Self.selectedSkillMarkdown(from: skillMarkdowns) else {
            throw SkillFileError.invalidSkillArchive
        }

        let ignored = skillMarkdowns.filter { $0 != selected }.sorted()
        let skillMarkdownURL = root.appendingPathComponent(selected)
        return SkillImportPlan(
            skillMarkdownURL: skillMarkdownURL,
            skillRootURL: skillMarkdownURL.deletingLastPathComponent(),
            selectedSkillMarkdownPath: selected,
            ignoredSkillMarkdownPaths: ignored
        )
    }

    private func validateArchivePath(_ path: String) throws {
        guard !path.isEmpty, !(path as NSString).isAbsolutePath else {
            throw SkillFileError.archiveEntryEscapes(path: path)
        }

        var components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.last?.isEmpty == true {
            components.removeLast()
        }
        guard !components.isEmpty else {
            throw SkillFileError.archiveEntryEscapes(path: path)
        }
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw SkillFileError.archiveEntryEscapes(path: path)
        }
        guard components.count <= maxPathDepth else {
            throw SkillFileError.archiveEntryTooDeep(path: path, limit: maxPathDepth)
        }
    }

    private func relativePath(for fileURL: URL, in baseDirectory: URL) throws -> String {
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        guard fileComponents.count > baseComponents.count,
            Array(fileComponents.prefix(baseComponents.count)) == baseComponents
        else {
            throw SkillFileError.archiveEntryEscapes(path: fileURL.path)
        }
        return fileComponents.dropFirst(baseComponents.count).joined(separator: "/")
    }

    private static func selectedSkillMarkdown(from paths: [String]) -> String? {
        paths.min { lhs, rhs in
            let lhsDepth = lhs.split(separator: "/").count
            let rhsDepth = rhs.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs < rhs
        }
    }

    private static func isContained(_ fileURL: URL, in baseDirectory: URL) -> Bool {
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        return fileComponents.count >= baseComponents.count
            && Array(fileComponents.prefix(baseComponents.count)) == baseComponents
    }

    private static func listArchiveEntries(in zipURL: URL) throws -> [SkillArchiveEntry] {
        let result: SkillArchiveProcessResult
        do {
            result = try SkillArchiveProcessRunner.run(
                executablePath: "/usr/bin/unzip",
                arguments: ["-l", zipURL.path],
                timeoutSeconds: 30
            )
        } catch {
            throw SkillFileError.archiveListingFailed(error.localizedDescription)
        }

        if result.timedOut {
            throw SkillFileError.archiveListingFailed(L("inspection timed out after 30 seconds"))
        }

        guard result.terminationStatus == 0 else {
            throw SkillFileError.archiveListingFailed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if result.outputTruncated {
            throw SkillFileError.archiveListingFailed(L("inspection output exceeded the supported limit"))
        }

        return result.output.split(separator: "\n").compactMap { line -> SkillArchiveEntry? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4, let size = Int64(parts[0]) else {
                return nil
            }
            let name = parts.dropFirst(3).joined(separator: " ")
            return SkillArchiveEntry(name: name, uncompressedSize: size)
        }
    }
}

struct SkillArchiveEntry: Sendable, Equatable {
    let name: String
    let uncompressedSize: Int64

    var isDirectory: Bool {
        name.hasSuffix("/")
    }
}

public struct SkillImportPlan: Sendable, Equatable {
    public let skillMarkdownURL: URL
    public let skillRootURL: URL
    public let selectedSkillMarkdownPath: String
    public let ignoredSkillMarkdownPaths: [String]
}

public struct SkillImportResult: Sendable, Equatable {
    public let skill: Skill
    public let notes: [String]
}

struct SkillArchiveProcessResult: Sendable, Equatable {
    let terminationStatus: Int32
    let output: String
    let outputTruncated: Bool
    let timedOut: Bool
}

enum SkillArchiveProcessRunner {
    private static let outputLimitBytes = 256 * 1024
    private static let chunkBytes = 16 * 1024
    private static let forcedKillGraceSeconds: TimeInterval = 2

    static func run(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        timeoutSeconds: TimeInterval
    ) throws -> SkillArchiveProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminated.signal()
        }

        try process.run()

        let reader = SkillArchiveProcessOutputReader(
            fileHandle: pipe.fileHandleForReading,
            maxBytes: outputLimitBytes,
            chunkBytes: chunkBytes
        )
        reader.start()

        let deadline = DispatchTime.now() + .nanoseconds(Self.nanoseconds(timeoutSeconds))
        let timedOut = terminated.wait(timeout: deadline) == .timedOut
        if timedOut {
            process.terminate()
            let graceDeadline = DispatchTime.now() + .nanoseconds(Self.nanoseconds(forcedKillGraceSeconds))
            if terminated.wait(timeout: graceDeadline) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: DispatchTime.now() + .nanoseconds(Self.nanoseconds(forcedKillGraceSeconds)))
            }
        }

        _ = reader.waitForEnd(timeoutSeconds: forcedKillGraceSeconds)

        let status = process.isRunning ? Int32(-1) : process.terminationStatus
        return SkillArchiveProcessResult(
            terminationStatus: status,
            output: reader.outputString,
            outputTruncated: reader.outputWasTruncated,
            timedOut: timedOut
        )
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let maxSafeSeconds = TimeInterval(Int.max / 1_000_000_000)
        if seconds >= maxSafeSeconds { return Int.max }
        return Int(seconds * 1_000_000_000)
    }
}

private final class SkillArchiveProcessOutputReader: @unchecked Sendable {
    private let fileHandle: FileHandle
    private let maxBytes: Int
    private let chunkBytes: Int
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()
    private var truncated = false

    init(fileHandle: FileHandle, maxBytes: Int, chunkBytes: Int) {
        self.fileHandle = fileHandle
        self.maxBytes = maxBytes
        self.chunkBytes = chunkBytes
    }

    func start() {
        DispatchQueue.global(qos: .utility).async {
            defer { self.done.signal() }
            while true {
                let chunk = (try? self.fileHandle.read(upToCount: self.chunkBytes)) ?? Data()
                if chunk.isEmpty { return }
                self.append(chunk)
            }
        }
    }

    func waitForEnd(timeoutSeconds: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + .nanoseconds(Self.nanoseconds(timeoutSeconds))
        return done.wait(timeout: deadline) == .success
    }

    var outputString: String {
        lock.lock()
        let snapshot = data
        let wasTruncated = truncated
        lock.unlock()

        var output = String(data: snapshot, encoding: .utf8) ?? ""
        if wasTruncated {
            output += "\n[output truncated]"
        }
        return output
    }

    var outputWasTruncated: Bool {
        lock.lock()
        let wasTruncated = truncated
        lock.unlock()
        return wasTruncated
    }

    private func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }

        let remaining = maxBytes - data.count
        if remaining <= 0 {
            truncated = true
            return
        }

        if chunk.count <= remaining {
            data.append(chunk)
        } else {
            data.append(contentsOf: chunk.prefix(remaining))
            truncated = true
        }
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let maxSafeSeconds = TimeInterval(Int.max / 1_000_000_000)
        if seconds >= maxSafeSeconds { return Int.max }
        return Int(seconds * 1_000_000_000)
    }
}
