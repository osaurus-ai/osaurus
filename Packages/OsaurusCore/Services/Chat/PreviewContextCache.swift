//
//  PreviewContextCache.swift
//  osaurus
//
//  Coalesces welcome/pre-send preview composition across chat sessions.
//

import Foundation

/// Process-wide, main-actor cache for `SystemPromptComposer.composePreviewContext`.
///
/// Every open `ChatSession` subscribes to the same prompt-shape notifications
/// and recomposes its preview on the same debounced main-run-loop tick. The
/// compose is synchronous and `@MainActor` (snapshot capture, spawn-target
/// resolution, tool schema compaction, routing JSON), so N windows meant N
/// full composes back-to-back on the main thread — long enough to trip the
/// 3 s app-hang detector (APPLE-MACOS-3E9 / APPLE-MACOS-1VA).
///
/// Entries are keyed by every explicit compose input plus a generation that
/// bumps on any prompt-shape notification, and expire after a short TTL so
/// state that changes without a notification can't stay stale for long. The
/// cache only removes duplicate work within one signal burst; it never
/// changes what a single compose returns.
@MainActor
final class PreviewContextCache {
    static let shared = PreviewContextCache()

    /// Bounds staleness for state that changes without a notification.
    /// Long enough to cover all sessions reacting to one debounced signal.
    static let entryLifetime: TimeInterval = 0.5

    private struct Entry {
        let generation: UInt64
        let createdAt: Date
        let context: ComposedContext
    }

    private var entries: [String: Entry] = [:]
    private(set) var generation: UInt64 = 0
    private var observers: [NSObjectProtocol] = []

    init(notificationNames: [Notification.Name] = ChatSession.promptShapeNotificationNames) {
        observers = notificationNames.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.invalidate() }
            }
        }
    }

    /// Drop every entry and advance the generation.
    func invalidate() {
        generation &+= 1
        entries.removeAll(keepingCapacity: true)
    }

    static func key(
        agentId: UUID,
        executionMode: ExecutionMode,
        model: String?,
        modelType: String?,
        source: SessionSource?
    ) -> String {
        // `String(reflecting:)` captures the full value of the mode,
        // including the host-folder context, so two sessions on different
        // folders never share an entry.
        [
            agentId.uuidString,
            String(reflecting: executionMode),
            model ?? "",
            modelType ?? "",
            source?.rawValue ?? "",
        ].joined(separator: "\u{1F}")
    }

    func context(
        forKey key: String,
        now: Date = Date(),
        compose: () -> ComposedContext
    ) -> ComposedContext {
        if let entry = entries[key],
            entry.generation == generation,
            now.timeIntervalSince(entry.createdAt) < Self.entryLifetime
        {
            return entry.context
        }
        let context = compose()
        entries[key] = Entry(generation: generation, createdAt: now, context: context)
        return context
    }
}
