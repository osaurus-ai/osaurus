//
//  MemoryPressureResponder.swift
//  osaurus
//
//  Responds to macOS memory-pressure events by proactively freeing app-side
//  caches (warning) and unloading idle model weights (critical), instead of
//  relying solely on NSCache's passive eviction.
//
//  This never refuses loads or applies hidden RAM limits — it only frees
//  reconstructible caches and lease-free models through the existing
//  `ModelRuntime.unload` path, and logs every action so the behavior is
//  observable.
//

import Foundation
import os

public final class MemoryPressureResponder: @unchecked Sendable {
    public static let shared = MemoryPressureResponder()

    private static let log = Logger(subsystem: "com.dinoki.osaurus", category: "MemoryPressure")

    private let queue = DispatchQueue(label: "com.dinoki.osaurus.memory-pressure", qos: .utility)
    private var source: DispatchSourceMemoryPressure?

    private init() {}

    /// Install the memory-pressure handler. Idempotent; called once at launch.
    public func start() {
        queue.sync {
            guard source == nil else { return }
            let src = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: queue
            )
            src.setEventHandler { [weak self] in
                guard let self, let source = self.source else { return }
                let event = source.data
                if event.contains(.critical) {
                    Self.log.warning("critical memory pressure — freeing caches and idle models")
                    self.respondToWarning()
                    self.respondToCritical()
                } else if event.contains(.warning) {
                    Self.log.info("memory pressure warning — freeing app caches")
                    self.respondToWarning()
                }
            }
            src.activate()
            source = src
        }
    }

    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
        }
    }

    /// Warning tier: drop reconstructible UI caches and return MLX's
    /// freed-buffer pool to the allocator. Everything here is re-derived
    /// lazily on next use; nothing user-visible is lost.
    private func respondToWarning() {
        ThreadCache.shared.clear()
        ChatImageCache.shared.removeAll()
        LaTeXRenderer.shared.clearCache()
        SymbolImageCache.clear()
        NativeHeaderView.clearMonogramCache()
        Task {
            await ThemePreviewImageCache.shared.removeAll()
            await ModelRuntime.shared.trimFreedBufferCacheUnderMemoryPressure()
        }
    }

    /// Critical tier: additionally release idle (lease-free) model weights
    /// through the normal unload path and purge detection memo caches.
    private func respondToCritical() {
        LocalReasoningCapability.invalidate()
        Task {
            let unloaded = await ModelRuntime.shared.unloadIdleModelsUnderMemoryPressure()
            if unloaded.isEmpty {
                Self.log.info("critical memory pressure: no idle models to unload")
            } else {
                Self.log.warning(
                    "critical memory pressure: unloaded \(unloaded.joined(separator: ", "), privacy: .public)"
                )
            }
        }
    }
}
