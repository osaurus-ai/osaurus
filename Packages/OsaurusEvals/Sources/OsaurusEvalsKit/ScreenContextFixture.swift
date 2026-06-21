//
//  ScreenContextFixture.swift
//  OsaurusEvalsKit
//
//  A captured (or synthetic) macOS screen state the `ScreenContextDistiller`
//  can be replayed against deterministically. The distiller is pure over an
//  injected `MacDriver`, so a frozen accessibility tree + listings + a direct
//  focused-element read is everything it needs to produce a `[Screen Context]`
//  block — no real Accessibility, SkyLight, or Screen Recording. That makes a
//  `screen_context` eval reproducible and CI-safe.
//
//  Every member is `Codable` (all the `CU*` contract types are), so a fixture
//  can be hand-authored as synthetic JSON, captured from a real app via the
//  `capture-screen` CLI, or inlined in a case's `expect.screenContext.scene`.
//  `CUImage` is deliberately excluded — these are AX-only fixtures (the
//  distiller is text-only and never reads pixels).
//

import Foundation
import OsaurusCore

public struct ScreenContextFixture: Sendable, Codable, Equatable {

    /// The single capture the distiller reads for the working app. Mirrors the
    /// scored fields of `CUSnapshot` (the image and ids are irrelevant to the
    /// text distillation) plus `truncated`, which gates the editor-fallback
    /// `find(...)` path so a fixture can reproduce the chrome-heavy-app case
    /// where the bounded traversal misses the editor.
    public struct Snapshot: Sendable, Codable, Equatable {
        public let app: String
        public let focusedWindow: String?
        /// True when the real AX traversal would have hit its element budget
        /// before finishing — the signal that triggers the distiller's targeted
        /// `textarea` fallback search.
        public let truncated: Bool
        public let windows: [CUWindowSummary]
        public let elements: [CUElement]

        public init(
            app: String,
            focusedWindow: String? = nil,
            truncated: Bool = false,
            windows: [CUWindowSummary] = [],
            elements: [CUElement] = []
        ) {
            self.app = app
            self.focusedWindow = focusedWindow
            self.truncated = truncated
            self.windows = windows
            self.elements = elements
        }

        private enum CodingKeys: String, CodingKey {
            case app, focusedWindow, truncated, windows, elements
        }

        // Lenient decode so a hand-authored synthetic fixture can omit empty
        // collections / the truncated flag. Encoding stays synthesized (the
        // capture CLI writes every key).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.app = try c.decode(String.self, forKey: .app)
            self.focusedWindow = try c.decodeIfPresent(String.self, forKey: .focusedWindow)
            self.truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
            self.windows = try c.decodeIfPresent([CUWindowSummary].self, forKey: .windows) ?? []
            self.elements = try c.decodeIfPresent([CUElement].self, forKey: .elements) ?? []
        }
    }

    /// Running apps the distiller enumerates (`listApps`). The working app is
    /// resolved from `activeWindow` first, falling back to the first non-self
    /// app here.
    public let apps: [CUAppListing]
    /// The frontmost window (`activeWindow`). Drives working-app resolution.
    public let activeWindow: CUActiveWindow?
    /// Per-pid window listings (`listWindows`). JSON object keys are strings, so
    /// the pid is stored as its decimal string (e.g. `"100"`).
    public let windowsByPid: [String: [CUWindowInfo]]
    /// The working app's captured accessibility tree.
    public let snapshot: Snapshot
    /// The direct focused-element read (`focusedContent`) — the primary "what am
    /// I looking at" signal, independent of the bounded traversal.
    public let focusedContent: CUFocusedContent?

    public init(
        apps: [CUAppListing],
        activeWindow: CUActiveWindow?,
        windowsByPid: [String: [CUWindowInfo]],
        snapshot: Snapshot,
        focusedContent: CUFocusedContent? = nil
    ) {
        self.apps = apps
        self.activeWindow = activeWindow
        self.windowsByPid = windowsByPid
        self.snapshot = snapshot
        self.focusedContent = focusedContent
    }

    private enum CodingKeys: String, CodingKey {
        case apps, activeWindow, windowsByPid, snapshot, focusedContent
    }

    // Lenient decode so a hand-authored synthetic fixture can omit the
    // per-pid window map and the focused read when they aren't needed.
    // Encoding stays synthesized (the capture CLI writes every key).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.apps = try c.decodeIfPresent([CUAppListing].self, forKey: .apps) ?? []
        self.activeWindow = try c.decodeIfPresent(CUActiveWindow.self, forKey: .activeWindow)
        self.windowsByPid =
            try c.decodeIfPresent([String: [CUWindowInfo]].self, forKey: .windowsByPid) ?? [:]
        self.snapshot = try c.decode(Snapshot.self, forKey: .snapshot)
        self.focusedContent = try c.decodeIfPresent(CUFocusedContent.self, forKey: .focusedContent)
    }

    // MARK: - Driver helpers

    /// The pid the distiller will resolve as the working app — `activeWindow`'s
    /// pid when present, else the first listed app's. The `FixtureCUDriver`
    /// serves the snapshot for whichever pid it's asked about, but this is the
    /// one a faithful fixture keys its `windowsByPid` entry on.
    public var workingPid: Int32 {
        activeWindow?.pid ?? apps.first?.pid ?? 0
    }

    /// Window listings for `pid`, or an empty list when the fixture didn't
    /// capture that app's windows.
    public func windows(forPid pid: Int32) -> [CUWindowInfo] {
        windowsByPid[String(pid)] ?? []
    }

    /// Materialize the fixture's `Snapshot` into a real `CUSnapshot` for the
    /// requested pid. `maxElements` is honored (prefix truncation) so the
    /// distiller's chrome-budget behavior is reproduced; `truncated` is OR'd
    /// with "we actually clipped" so either the fixture's flag or a too-small
    /// budget trips the editor fallback.
    public func cuSnapshot(pid: Int32, snapshotId: Int, maxElements: Int?) -> CUSnapshot {
        let all = snapshot.elements
        let clipped: [CUElement]
        let didClip: Bool
        if let cap = maxElements, cap >= 0, all.count > cap {
            clipped = Array(all.prefix(cap))
            didClip = true
        } else {
            clipped = all
            didClip = false
        }
        return CUSnapshot(
            snapshotId: snapshotId,
            pid: pid,
            app: snapshot.app,
            focusedWindow: snapshot.focusedWindow,
            tier: .ax,
            truncated: snapshot.truncated || didClip,
            windows: snapshot.windows,
            elements: clipped,
            image: nil
        )
    }
}
