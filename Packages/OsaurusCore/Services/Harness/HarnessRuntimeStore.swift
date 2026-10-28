//
//  HarnessRuntimeStore.swift
//  osaurus
//
//  Persistence for user-registered harness runtimes at
//  `~/.osaurus/config/harness-runtimes.json`.
//

import Combine
import Foundation

@MainActor
public final class HarnessRuntimeStore: ObservableObject {
    public static let shared = HarnessRuntimeStore()

    /// Optional directory override for tests.
    public static var overrideDirectory: URL?

    @Published public private(set) var runtimes: [HarnessRuntime] = []

    private struct FileContents: Codable {
        var runtimes: [HarnessRuntime]
    }

    private var loaded = false

    init() {}

    /// Load from disk on first use. The Claude Code runtime is seeded only
    /// when the file has never been written, so a user who deletes it keeps
    /// it deleted.
    public func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let url = Self.fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            runtimes = [.builtInClaudeCode]
            save()
            return
        }
        if let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(FileContents.self, from: data)
        {
            runtimes = decoded.runtimes
        } else {
            // Unreadable file: run with nothing rather than overwrite it.
            print("[Osaurus] Failed to decode harness-runtimes.json — file preserved")
            runtimes = []
        }
    }

    public func all() -> [HarnessRuntime] {
        loadIfNeeded()
        return runtimes
    }

    public func runtime(id: UUID) -> HarnessRuntime? {
        loadIfNeeded()
        return runtimes.first { $0.id == id }
    }

    public func upsert(_ runtime: HarnessRuntime) {
        loadIfNeeded()
        if let index = runtimes.firstIndex(where: { $0.id == runtime.id }) {
            runtimes[index] = runtime
        } else {
            runtimes.append(runtime)
        }
        save()
        NotificationCenter.default.post(name: .harnessRuntimesChanged, object: runtime.id)
    }

    public func remove(id: UUID) {
        loadIfNeeded()
        runtimes.removeAll { $0.id == id }
        save()
        NotificationCenter.default.post(name: .harnessRuntimesChanged, object: id)
    }

    /// Make sure the Claude Code runtime exists (used by onboarding and by the
    /// migration of agents that were on a `claude-code/…` model) and return it.
    @discardableResult
    public func ensureClaudeCodeRuntime() -> HarnessRuntime {
        loadIfNeeded()
        if let existing = runtimes.first(where: { $0.id == HarnessRuntime.builtInClaudeCodeId }) {
            return existing
        }
        if let anyClaude = runtimes.first(where: { $0.kind == .claudeCode }) {
            return anyClaude
        }
        let seeded = HarnessRuntime.builtInClaudeCode
        upsert(seeded)
        return seeded
    }

    /// Test seam: forget cached state so the next read reloads.
    public func resetForTests() {
        loaded = false
        runtimes = []
    }

    // MARK: - Disk

    private static func fileURL() -> URL {
        let dir = overrideDirectory ?? OsaurusPaths.config()
        return dir.appendingPathComponent("harness-runtimes.json")
    }

    private func save() {
        let url = Self.fileURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(FileContents(runtimes: runtimes))
            try data.write(to: url, options: .atomic)
        } catch {
            print("[Osaurus] Failed to save harness-runtimes.json: \(error)")
        }
    }
}

extension Notification.Name {
    public static let harnessRuntimesChanged = Notification.Name("HarnessRuntimesChanged")
}
