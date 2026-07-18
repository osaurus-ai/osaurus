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

enum SkillArchiveProcessRunnerError: Error, Sendable, Equatable {
    case outputDrainIncomplete
}

protocol SkillArchiveProcessOutputStreaming: Sendable {
    func start(
        onChunk: @escaping @Sendable (Data) -> Void,
        onCompletion: @escaping @Sendable ((any Error)?) -> Void
    )
    func cancel()
}

struct SkillArchiveProcessConfiguration: Sendable {
    static let `default` = SkillArchiveProcessConfiguration()

    let outputLimitBytes: Int
    let chunkBytes: Int
    let cleanupGraceSeconds: TimeInterval
    let outputStream: (any SkillArchiveProcessOutputStreaming)?

    init(
        outputLimitBytes: Int = 256 * 1024,
        chunkBytes: Int = 16 * 1024,
        cleanupGraceSeconds: TimeInterval = 2,
        outputStream: (any SkillArchiveProcessOutputStreaming)? = nil
    ) {
        self.outputLimitBytes = outputLimitBytes
        self.chunkBytes = chunkBytes
        self.cleanupGraceSeconds = cleanupGraceSeconds
        self.outputStream = outputStream
    }
}

enum SkillArchiveProcessRunner {
    private static let waitPollNanoseconds = 50_000_000

    private enum WaitOutcome {
        case exited
        case timedOut
        case cancelled
        case outputReadFailed
    }

    static func run(
        executablePath: String,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        timeoutSeconds: TimeInterval,
        configuration: SkillArchiveProcessConfiguration = .default
    ) throws -> SkillArchiveProcessResult {
        if Task.isCancelled { throw CancellationError() }

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
        try? pipe.fileHandleForWriting.close()

        let outputStream = configuration.outputStream
            ?? SkillArchiveDispatchOutputStream(
                fileHandle: pipe.fileHandleForReading,
                chunkBytes: configuration.chunkBytes
            )
        let reader = SkillArchiveProcessOutputReader(
            outputStream: outputStream,
            maxBytes: configuration.outputLimitBytes
        )
        reader.start()

        let waitOutcome = Self.waitForProcess(
            terminated: terminated,
            reader: reader,
            timeoutSeconds: timeoutSeconds
        )
        switch waitOutcome {
        case .exited:
            process.waitUntilExit()
        case .timedOut, .cancelled, .outputReadFailed:
            Self.stopAndReap(
                process,
                terminated: terminated,
                graceSeconds: configuration.cleanupGraceSeconds
            )
        }
        process.terminationHandler = nil

        let completion: SkillArchiveProcessOutputCompletion
        if let drained = reader.waitForEnd(timeoutSeconds: configuration.cleanupGraceSeconds) {
            completion = drained
        } else {
            // DispatchIO cancellation waits for its cleanup callback, so no
            // descriptor callback can race deletion of an extraction directory.
            _ = reader.cancelAndWait()
            if waitOutcome == .cancelled || Task.isCancelled {
                throw CancellationError()
            }
            throw SkillArchiveProcessRunnerError.outputDrainIncomplete
        }

        if waitOutcome == .cancelled || Task.isCancelled {
            throw CancellationError()
        }
        if let readError = completion.readError {
            throw readError
        }

        return SkillArchiveProcessResult(
            terminationStatus: process.terminationStatus,
            output: completion.output,
            outputTruncated: completion.outputWasTruncated,
            timedOut: waitOutcome == .timedOut
        )
    }

    private static func waitForProcess(
        terminated: DispatchSemaphore,
        reader: SkillArchiveProcessOutputReader,
        timeoutSeconds: TimeInterval
    ) -> WaitOutcome {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let timeoutNanoseconds = UInt64(Self.nanoseconds(timeoutSeconds))
        let (candidateDeadline, overflow) = startedAt.addingReportingOverflow(timeoutNanoseconds)
        let deadline = overflow ? UInt64.max : candidateDeadline

        while true {
            if Task.isCancelled { return .cancelled }
            if reader.readErrorDetected { return .outputReadFailed }
            if terminated.wait(timeout: .now()) == .success { return .exited }

            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .timedOut }
            let remaining = deadline - now
            let waitNanoseconds = Int(min(remaining, UInt64(Self.waitPollNanoseconds)))
            if terminated.wait(timeout: .now() + .nanoseconds(waitNanoseconds)) == .success {
                return .exited
            }
        }
    }

    private static func stopAndReap(
        _ process: Process,
        terminated: DispatchSemaphore,
        graceSeconds: TimeInterval
    ) {
        if terminated.wait(timeout: .now()) == .timedOut {
            if process.isRunning {
                process.terminate()
            }

            let graceDeadline = DispatchTime.now() + .nanoseconds(Self.nanoseconds(graceSeconds))
            if terminated.wait(timeout: graceDeadline) == .timedOut,
                terminated.wait(timeout: .now()) == .timedOut,
                process.isRunning {
                // The termination latch is checked immediately before SIGKILL
                // so Foundation has not announced and reaped this child PID.
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        // Cleanup callers may remove process inputs and outputs as soon as run
        // returns, so a bounded post-kill wait is not sufficient here.
        process.waitUntilExit()
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let maxSafeSeconds = TimeInterval(Int.max / 1_000_000_000)
        if seconds >= maxSafeSeconds { return Int.max }
        return Int(seconds * 1_000_000_000)
    }
}

private struct SkillArchiveProcessOutputCompletion {
    let output: String
    let outputWasTruncated: Bool
    let readError: (any Error)?
}

private final class SkillArchiveProcessOutputReader: @unchecked Sendable {
    private let outputStream: any SkillArchiveProcessOutputStreaming
    private let maxBytes: Int
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var data = Data()
    private var truncated = false
    private var readError: (any Error)?
    private var finished = false

    init(outputStream: any SkillArchiveProcessOutputStreaming, maxBytes: Int) {
        self.outputStream = outputStream
        self.maxBytes = maxBytes
    }

    func start() {
        outputStream.start(
            onChunk: { [self] chunk in append(chunk) },
            onCompletion: { [self] error in finish(with: error) }
        )
    }

    func waitForEnd(timeoutSeconds: TimeInterval) -> SkillArchiveProcessOutputCompletion? {
        let deadline = DispatchTime.now() + .nanoseconds(Self.nanoseconds(timeoutSeconds))
        guard done.wait(timeout: deadline) == .success else { return nil }
        return completionSnapshot()
    }

    func cancelAndWait() -> SkillArchiveProcessOutputCompletion {
        outputStream.cancel()
        done.wait()
        return completionSnapshot()
    }

    var readErrorDetected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readError != nil
    }

    private func finish(with error: (any Error)?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        readError = error
        finished = true
        lock.unlock()
        done.signal()
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

    private func completionSnapshot() -> SkillArchiveProcessOutputCompletion {
        lock.lock()
        let snapshot = data
        let wasTruncated = truncated
        let error = readError
        lock.unlock()

        var output = String(data: snapshot, encoding: .utf8) ?? ""
        if wasTruncated {
            output += "\n[output truncated]"
        }
        return SkillArchiveProcessOutputCompletion(
            output: output,
            outputWasTruncated: wasTruncated,
            readError: error
        )
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let maxSafeSeconds = TimeInterval(Int.max / 1_000_000_000)
        if seconds >= maxSafeSeconds { return Int.max }
        return Int(seconds * 1_000_000_000)
    }
}

/// DispatchIO owns descriptor access until its cleanup callback runs. Retaining
/// the FileHandle prevents ARC from closing that descriptor before the join.
private final class SkillArchiveDispatchOutputStream: SkillArchiveProcessOutputStreaming, @unchecked Sendable {
    private let state: SkillArchiveDispatchOutputState
    private let channel: DispatchIO
    private let fileHandle: FileHandle
    private let chunkBytes: Int
    private let queue = DispatchQueue(label: "ai.osaurus.skill-archive-output", qos: .utility)

    init(fileHandle: FileHandle, chunkBytes: Int) {
        let state = SkillArchiveDispatchOutputState()
        self.state = state
        self.fileHandle = fileHandle
        self.chunkBytes = chunkBytes
        self.channel = DispatchIO(
            type: .stream,
            fileDescriptor: fileHandle.fileDescriptor,
            queue: queue
        ) { errorCode in
            state.finishCleanup(errorCode: errorCode)
        }
    }

    func start(
        onChunk: @escaping @Sendable (Data) -> Void,
        onCompletion: @escaping @Sendable ((any Error)?) -> Void
    ) {
        state.installCompletion(onCompletion)
        channel.setLimit(lowWater: chunkBytes)
        channel.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, dispatchData, errorCode in
            guard let self else { return }
            if let dispatchData, !dispatchData.isEmpty {
                onChunk(Data(dispatchData))
            }

            guard done || errorCode != 0 else { return }
            if state.requestClose(errorCode: errorCode) {
                channel.close(flags: errorCode == 0 ? [] : .stop)
            }
        }
    }

    func cancel() {
        if state.requestClose(errorCode: ECANCELED) {
            channel.close(flags: .stop)
        }
    }
}

private final class SkillArchiveDispatchOutputState: @unchecked Sendable {
    private let lock = NSLock()
    private var completionHandler: (@Sendable ((any Error)?) -> Void)?
    private var pendingError: (any Error)?
    private var closeRequested = false
    private var cleanupFinished = false
    private var completionDelivered = false

    func installCompletion(_ handler: @escaping @Sendable ((any Error)?) -> Void) {
        lock.lock()
        completionHandler = handler
        let shouldDeliver = cleanupFinished && !completionDelivered
        if shouldDeliver {
            completionDelivered = true
            completionHandler = nil
        }
        let error = pendingError
        lock.unlock()

        if shouldDeliver {
            handler(error)
        }
    }

    func requestClose(errorCode: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closeRequested else { return false }

        closeRequested = true
        if errorCode != 0 {
            pendingError = Self.posixError(errorCode)
        }
        return true
    }

    func finishCleanup(errorCode: Int32) {
        lock.lock()
        if pendingError == nil, errorCode != 0 {
            pendingError = Self.posixError(errorCode)
        }
        cleanupFinished = true
        guard let handler = completionHandler, !completionDelivered else {
            lock.unlock()
            return
        }

        completionDelivered = true
        let error = pendingError
        completionHandler = nil
        lock.unlock()
        handler(error)
    }

    private static func posixError(_ code: Int32) -> any Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}
