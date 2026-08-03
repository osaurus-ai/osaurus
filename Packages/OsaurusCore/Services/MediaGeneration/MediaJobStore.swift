//
//  MediaJobStore.swift
//  osaurus
//

import Foundation

enum DurableMediaJobState: String, Codable, Sendable {
    case queued
    case retrieving
    case completed
    case failed
}

struct DurableMediaJob: Codable, Identifiable, Sendable {
    var id: UUID
    var backend: MediaGenerationBackend
    var providerID: UUID?
    var modelID: String
    var kind: MediaGenerationKind
    var queueID: String
    var downloadURL: URL?
    var quoteUSD: Double?
    var state: DurableMediaJobState
    var outputURL: URL?
    var errorMessage: String?
    /// Optional for backward-compatible decoding of jobs written before
    /// cleanup was tracked independently from generation completion.
    var cleanupPending: Bool? = nil
    var createdAt: Date
    var updatedAt: Date
}

actor MediaJobStore {
    static let shared = MediaJobStore()

    private let fileURL: URL
    private var jobs: [UUID: DurableMediaJob]

    init(fileURL: URL = OsaurusPaths.mediaJobsFile()) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([DurableMediaJob].self, from: data)
        {
            self.jobs = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
        } else {
            self.jobs = [:]
        }
    }

    func upsert(_ job: DurableMediaJob) throws {
        jobs[job.id] = job
        try persist()
    }

    func update(
        id: UUID,
        state: DurableMediaJobState,
        outputURL: URL? = nil,
        errorMessage: String? = nil,
        cleanupPending: Bool? = nil
    ) throws {
        guard var job = jobs[id] else { return }
        job.state = state
        job.outputURL = outputURL ?? job.outputURL
        job.errorMessage = errorMessage
        if let cleanupPending {
            job.cleanupPending = cleanupPending
        }
        job.updatedAt = Date()
        jobs[id] = job
        try persist()
    }

    func pending() -> [DurableMediaJob] {
        jobs.values
            .filter {
                $0.state == .queued
                    || $0.state == .retrieving
                    || ($0.state == .completed && $0.cleanupPending == true)
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func all() -> [DurableMediaJob] {
        jobs.values.sorted { $0.createdAt > $1.createdAt }
    }

    func job(id: UUID) -> DurableMediaJob? {
        jobs[id]
    }

    func pruneTerminalJobs(olderThan cutoff: Date) throws {
        let removable = jobs.values.filter {
            ($0.state == .completed || $0.state == .failed)
                && $0.updatedAt < cutoff
                && $0.cleanupPending != true
        }
        let generatedRoot = OsaurusPaths.generatedVideos().standardizedFileURL.path
        for job in removable {
            if let output = job.outputURL?.standardizedFileURL,
                output.path.hasPrefix(generatedRoot + "/")
            {
                try? FileManager.default.removeItem(at: output)
            }
            jobs.removeValue(forKey: job.id)
        }
        if !removable.isEmpty {
            try persist()
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let values = jobs.values.sorted { $0.createdAt < $1.createdAt }
        let data = try JSONEncoder().encode(values)
        try data.write(to: fileURL, options: .atomic)
    }
}
