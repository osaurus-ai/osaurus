//
//  ScheduleStore.swift
//  osaurus
//
//  Persistence layer for scheduled tasks.
//

import Foundation

/// Handles persistence of schedules to disk
public enum ScheduleStore {
    // MARK: - Directory Management

    private static var schedulesDirectory: URL {
        let dir = OsaurusPaths.resolvePath(new: OsaurusPaths.schedules(), legacy: "Schedules")
        OsaurusPaths.ensureExistsSilent(dir)
        return dir
    }

    private static func fileURL(for id: UUID) -> URL {
        schedulesDirectory.appendingPathComponent("\(id.uuidString).json")
    }

    // MARK: - CRUD Operations

    /// Load all schedules from disk
    public static func loadAll() -> [Schedule] {
        let fm = FileManager.default
        let dir = schedulesDirectory

        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var schedules: [Schedule] = []

        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let schedule = try decoder.decode(Schedule.self, from: data)
                schedules.append(schedule)
            } catch {
                print("[Osaurus] Failed to load schedule from \(file.lastPathComponent): \(error)")
            }
        }

        // Sort by creation date (newest first)
        return schedules.sorted { $0.createdAt > $1.createdAt }
    }

    /// Load a single schedule by ID
    public static func load(id: UUID) -> Schedule? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Schedule.self, from: data)
        } catch {
            print("[Osaurus] Failed to load schedule \(id): \(error)")
            return nil
        }
    }

    /// Save a schedule to disk
    public static func save(_ schedule: Schedule) {
        let url = fileURL(for: schedule.id)
        let previous = load(id: schedule.id)
        var scheduleToSave = schedule
        if let previous {
            scheduleToSave.mergeRunHistory(previous.runHistory)
        }
        applyHistoryTransitions(to: &scheduleToSave, previous: previous)

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(scheduleToSave)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("[Osaurus] Failed to save schedule \(schedule.id): \(error)")
        }
    }

    /// Delete a schedule from disk
    /// - Returns: true if deletion was successful
    @discardableResult
    public static func delete(id: UUID) -> Bool {
        let url = fileURL(for: id)

        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            print("[Osaurus] Failed to delete schedule \(id): \(error)")
            return false
        }
    }

    /// Delete all schedules
    public static func deleteAll() {
        let fm = FileManager.default
        let dir = schedulesDirectory

        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return
        }

        for file in files where file.pathExtension == "json" {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: - Batch Operations

    /// Update multiple schedules atomically
    public static func saveAll(_ schedules: [Schedule]) {
        for schedule in schedules {
            save(schedule)
        }
    }

    private static func applyHistoryTransitions(to schedule: inout Schedule, previous: Schedule?) {
        if previous?.lastTriggeredAt != schedule.lastTriggeredAt, let triggeredAt = schedule.lastTriggeredAt {
            schedule.recordRunStarted(at: triggeredAt)
        }

        if previous?.lastRunAt != schedule.lastRunAt, let lastRunAt = schedule.lastRunAt {
            schedule.recordRunSucceeded(endedAt: lastRunAt, chatSessionId: schedule.lastChatSessionId)
        }

        schedule.trimRunHistory()
    }
}
