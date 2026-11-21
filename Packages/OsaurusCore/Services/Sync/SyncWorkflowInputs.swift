//
//  SyncWorkflowInputs.swift
//  osaurus
//
//  The file and folder fields of a workflow an iPhone starts (`workflow_file_inputs`). The Mac never
//  takes a path from the phone: a path in a run's input is granted to its steps
//  (`WorkflowRunner.grantedPaths`), so every path here is one this Mac makes. A `file` field is either a
//  file the phone attached to a message on the manage conversation, saved here under the workflow's
//  `phone-inputs`, or, for a required field, what the workflow's last run used, if it still exists. A
//  `folder` field only the latter. A secret field is never filled from the phone, and a value from a run the
//  phone started is reused only if this Mac made it (one of its saved files).
//

import Foundation
import OsaurusSync
import os

@MainActor
enum SyncWorkflowInputs {
    nonisolated private static let log = Logger(subsystem: "ai.osaurus", category: "sync.workflow-inputs")

    typealias FileRef = SyncDeviceFeedContract.WorkflowFileRef

    /// The largest file taken from a phone, as for files sent the other way (`SyncWorkflowOutput`).
    nonisolated static let maxBytes: UInt64 = 10 * 1024 * 1024
    /// How long the attached file may take to arrive after the request that names it.
    nonisolated static let arrivalTimeout: Duration = .seconds(30)
    /// How long reading it may take once it has.
    nonisolated static let readTimeout: Duration = .seconds(60)
    /// The newest phone files kept per workflow: older ones go as new ones come.
    nonisolated static let keptPerWorkflow = 20

    enum Failure: Error, Equatable {
        case invalidInput(String)
    }

    // MARK: Last used

    /// The path the workflow's last run gave required file or folder `field`, which a phone start that sends
    /// nothing for it reuses. Only the last run's, so the phone shows the same one the run gets (`lastUsedName`);
    /// optional fields are left empty, as the phone left them. Only a path a person chose on this Mac (a run started
    /// from a workflow tab or the Workflows screen), or, from a run the phone started, a file this Mac saved for it:
    /// a path an agent, the Orchestrator, an event's payload or an outside caller gave is never granted again.
    /// Not checked to exist (`paths` does).
    nonisolated static func lastPath(_ field: DialogField, lastRun: WorkflowRun?) -> String? {
        guard field.required, field.type == .file || field.type == .folder, let lastRun,
            let path = lastRun.input.objectValue?[field.key]?.stringValue, path.hasPrefix("/")
        else { return nil }
        if lastRun.caller.fromPhone {
            let root = phoneInputs(lastRun.workflowID).standardizedFileURL.path + "/"
            guard URL(fileURLWithPath: path).standardizedFileURL.path.hasPrefix(root) else { return nil }
            return path
        }
        guard lastRun.caller.kind == .user, !lastRun.caller.isExternalSurface else { return nil }
        return path
    }

    /// `lastPath` by name only, for the phone to show ("Same as last time: headshot.jpg").
    nonisolated static func lastUsedName(_ field: DialogField, lastRun: WorkflowRun?) -> String? {
        guard let path = lastPath(field, lastRun: lastRun) else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// The workflow's last run, from the runs already in memory.
    static func lastRun(workflowId: UUID) -> WorkflowRun? {
        WorkflowRunStore.shared.recentRuns().first { $0.workflowID == workflowId }
    }

    /// Where a workflow's files from the phone are saved, a folder each.
    nonisolated static func phoneInputs(_ workflowId: UUID) -> URL {
        OsaurusPaths.workflowDirectory(workflowId).appendingPathComponent("phone-inputs", isDirectory: true)
    }

    // MARK: Paths for a start

    /// The paths this Mac gives `fields` for a phone's start: each attached file saved here, else `lastPath` if it
    /// still exists. Fields left out have none to give. Files are checked and read off the main actor.
    static func paths(
        workflowId: UUID,
        fields: [DialogField],
        files: [String: FileRef]?,
        device: String?
    ) async -> Result<[String: String], Failure> {
        let wanted = fields.filter { $0.type == .file || $0.type == .folder }
        let files = files ?? [:]
        guard !wanted.isEmpty else { return .success([:]) }
        // Only a `file` field takes an attachment, and only from a device whose request was signed.
        for key in files.keys {
            guard let field = wanted.first(where: { $0.key == key }), field.type == .file else {
                return .failure(.invalidInput("A file was sent for a field that doesn't take one."))
            }
        }
        if !files.isEmpty, device == nil {
            return .failure(.invalidInput("A file can only come from a device of yours."))
        }
        let last = lastRun(workflowId: workflowId)
        let inUse = foldersInUse(workflowId: workflowId)
        let picked = await Task.detached(priority: .userInitiated) { () -> Result<[String: String], Failure> in
            var out: [String: String] = [:]
            for field in wanted where files[field.key] == nil {
                guard let path = lastPath(field, lastRun: last) else { continue }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                    isDirectory.boolValue == (field.type == .folder)
                else {
                    let name = (path as NSString).lastPathComponent
                    return .failure(.invalidInput("\(name), last used for \(field.label), isn't on your Mac any more."))
                }
                out[field.key] = path
            }
            return .success(out)
        }.value
        var out: [String: String]
        switch picked {
        case .success(let picks): out = picks
        case .failure(let failure): return .failure(failure)
        }
        for (key, ref) in files.sorted(by: { $0.key < $1.key }) {
            switch await receive(ref, workflowId: workflowId, device: device ?? "", inUse: inUse) {
            case .success(let path): out[key] = path
            case .failure(let failure): return .failure(failure)
            }
        }
        return .success(out)
    }

    // MARK: Receiving

    /// Saves the attachment `ref` names into a new folder under the workflow's `phone-inputs`, once it has
    /// arrived, and returns the saved file's path. It must be on a message of this Mac's manage conversation
    /// that `device` wrote, and no larger than `maxBytes`.
    private static func receive(
        _ ref: FileRef,
        workflowId: UUID,
        device: String,
        inUse: Set<String>
    ) async -> Result<String, Failure> {
        guard let core = SyncService.shared.core else {
            return .failure(.invalidInput("Sync isn't running on this Mac."))
        }
        let found = await Task.detached(priority: .userInitiated) { () -> Result<(String, Blob), Failure> in
            await locate(ref, device: device, core: core)
        }.value
        let scope: String
        let blob: Blob
        switch found {
        case .success(let (foundScope, foundBlob)): (scope, blob) = (foundScope, foundBlob)
        case .failure(let failure): return .failure(failure)
        }
        let data: Data
        do {
            data = try await withTimeout(readTimeout) { try await core.readAttachment(scope: scope, hash: blob.hash) }
        } catch {
            log.error("phone file read failed: \(error.syncLogDetail, privacy: .public)")
            return .failure(.invalidInput("The file from your iPhone couldn't be read. Try again."))
        }
        guard UInt64(data.count) <= maxBytes else { return .failure(.invalidInput(tooLarge)) }
        let name = safeName(blob.name)
        return await Task.detached(priority: .userInitiated) { () -> Result<String, Failure> in
            let root = phoneInputs(workflowId)
            let folder = root.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            let file = folder.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file, options: [.withoutOverwriting])
            } catch {
                return .failure(.invalidInput("The file from your iPhone couldn't be saved on this Mac."))
            }
            prune(root, keeping: inUse.union([folder.standardizedFileURL.path]))
            return .success(file.path)
        }.value
    }

    /// The message and attachment `ref` names, waiting up to `arrivalTimeout` for the message to arrive.
    nonisolated private static func locate(
        _ ref: FileRef,
        device: String,
        core: SyncCore
    ) async -> Result<(String, Blob), Failure> {
        guard
            let manage = try? SyncDeviceFeedContract.conversation(
                kind: SyncDeviceFeedContract.manageKind,
                device: core.deviceKey(),
                core: core
            )
        else { return .failure(.invalidInput("This Mac's manage conversation isn't ready yet. Try again.")) }
        let deadline = ContinuousClock.now + arrivalTimeout
        while true {
            if let message = try? core.message(id: ref.message) {
                return check(message, ref: ref, scope: manage.scope, device: device)
            }
            guard ContinuousClock.now < deadline else {
                return .failure(.invalidInput("The file from your iPhone didn't arrive. Try again."))
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// `message` checked to be one `device` wrote on the manage conversation `scope`, holding the attachment
    /// `ref` names, no larger than `maxBytes`.
    nonisolated static func check(
        _ message: SyncMessage,
        ref: FileRef,
        scope: String,
        device: String
    ) -> Result<(String, Blob), Failure> {
        guard message.scope == scope, !message.isAgent,
            message.authorDevice.lowercased() == device.lowercased()
        else { return .failure(.invalidInput("That file didn't come from this iPhone.")) }
        guard let blob = message.blobs.first(where: { $0.hash == ref.blob }) else {
            return .failure(.invalidInput("That file isn't on its message."))
        }
        guard blob.size <= maxBytes else { return .failure(.invalidInput(tooLarge)) }
        return .success((scope, blob))
    }

    nonisolated private static let tooLarge = "The file is larger than 10 MB. Choose a smaller one."

    /// The phone's name for the file as one name in a folder: no path, no leading dot, at most 120 characters.
    nonisolated static func safeName(_ name: String?) -> String {
        let last = ((name ?? "") as NSString).lastPathComponent
        var cleaned = String(
            last.unicodeScalars.map { scalar -> Character in
                let unsafe = CharacterSet.controlCharacters.contains(scalar) || scalar == "/" || scalar == ":"
                return unsafe ? "_" : Character(scalar)
            })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.count > 120 {
            let ext = (cleaned as NSString).pathExtension
            let stem = String((cleaned as NSString).deletingPathExtension.prefix(ext.isEmpty ? 120 : 110))
            cleaned = ext.isEmpty ? stem : stem + "." + ext.prefix(9)
        }
        return cleaned.isEmpty ? "input" : cleaned
    }

    /// The phone-input folders a run of `workflowId` that hasn't ended still reads: never pruned.
    static func foldersInUse(workflowId: UUID) -> Set<String> {
        let root = phoneInputs(workflowId).standardizedFileURL.path + "/"
        var out: Set<String> = []
        for run in WorkflowRunStore.shared.recentRuns() where run.workflowID == workflowId && !run.status.isTerminal {
            for value in run.input.objectValue?.values.compactMap(\.stringValue) ?? [] {
                let path = URL(fileURLWithPath: value).standardizedFileURL
                if path.path.hasPrefix(root) { out.insert(path.deletingLastPathComponent().path) }
            }
        }
        return out
    }

    /// Removes the oldest folders under `root` past `keptPerWorkflow`, never one in `keeping` (standardised paths).
    nonisolated private static func prune(_ root: URL, keeping: Set<String>) {
        let fm = FileManager.default
        guard
            let folders = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])
        else { return }
        let dated = folders.map { url in
            (url, (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(keptPerWorkflow) where !keeping.contains(url.standardizedFileURL.path) {
            try? fm.removeItem(at: url)
        }
    }

    /// `body`'s result, or a timeout error once `limit` has passed, whether or not `body` heeds being cancelled:
    /// a task group would wait for it (a read through the core may not stop when asked).
    nonisolated private static func withTimeout<T: Sendable>(
        _ limit: Duration,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Result<T, Error>) -> Void = { result in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(with: result) }
            }
            let work = Task {
                do { finish(.success(try await body())) } catch { finish(.failure(error)) }
            }
            Task {
                try? await Task.sleep(for: limit)
                work.cancel()
                finish(.failure(CancellationError()))
            }
        }
    }
}
