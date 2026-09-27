//
//  FileChangeSummaryStore.swift
//  osaurus
//
//  Per-chat file change counts for the sidebar badge. One grouped query
//  for every chat, refreshed (coalesced) whenever the journal records or
//  reverts a change.
//

import Combine
import Foundation

@MainActor
public final class FileChangeSummaryStore: ObservableObject {
    public static let shared = FileChangeSummaryStore()

    @Published public private(set) var summaries: [String: FileChangeSessionSummary] = [:]

    private var observer: NSObjectProtocol?
    private var refreshTask: Task<Void, Never>?
    private var loaded = false

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .fileChangesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func summary(for sessionId: UUID) -> FileChangeSessionSummary? {
        if !loaded { refresh() }
        return summaries[sessionId.uuidString]
    }

    /// Ask the window showing `sessionId` to open its File Changes inspector.
    public static func requestPanel(sessionId: String, focusing setId: UUID? = nil) {
        var info: [String: Any] = ["sessionId": sessionId]
        if let setId { info["setId"] = setId }
        NotificationCenter.default.post(name: .fileChangesOpenPanel, object: nil, userInfo: info)
    }

    public func refresh() {
        loaded = true
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            // Coalesce bursts (a shell command settling, a multi-file revert).
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let next = await FileChangeJournal.shared.sessionSummaries()
            guard !Task.isCancelled, let self else { return }
            if next != self.summaries { self.summaries = next }
        }
    }
}
