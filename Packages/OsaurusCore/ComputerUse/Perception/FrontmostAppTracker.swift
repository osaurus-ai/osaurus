//
//  FrontmostAppTracker.swift
//  OsaurusCore — Computer Use
//
//  Records the most-recently-active application that is NOT Osaurus itself.
//
//  Why this exists: the screen-context snapshot freezes on the first send of
//  a chat session, at which point Osaurus is usually the frontmost app (the
//  user just clicked into the chat input). The interesting "what were you
//  doing" signal is the app that was frontmost *before* Osaurus took focus —
//  which macOS does not expose after the fact. So we observe activations from
//  app launch and remember the last non-self app, giving the distiller a
//  reliable working-app hint to fall back to.
//

import AppKit
import Combine
import Foundation

@MainActor
public final class FrontmostAppTracker: ObservableObject {
    public static let shared = FrontmostAppTracker()

    /// pid of the most-recently-active non-Osaurus app, or nil if none has
    /// been observed since the tracker started.
    public private(set) var lastNonSelfPid: Int32?

    private var observer: NSObjectProtocol?
    private let selfPid: Int32 = ProcessInfo.processInfo.processIdentifier
    private let selfBundleId: String? = Bundle.main.bundleIdentifier

    public init() {}

    /// Begin observing app activations. Idempotent. Call once at launch so we
    /// capture the user's working-app history before they open the chat.
    public func start() {
        guard observer == nil else { return }

        // Seed from the current frontmost app if it isn't us, so a chat opened
        // immediately after launch still has something to fall back to.
        if let front = NSWorkspace.shared.frontmostApplication {
            record(front)
        }

        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            let app =
                note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // `queue: .main` guarantees this runs on the main thread, so the
            // hop into MainActor state is safe and synchronous.
            MainActor.assumeIsolated {
                FrontmostAppTracker.shared.record(app)
            }
        }
    }

    private func record(_ app: NSRunningApplication?) {
        guard let app else { return }
        if app.processIdentifier == selfPid { return }
        if let bundleId = app.bundleIdentifier, bundleId == selfBundleId { return }
        lastNonSelfPid = app.processIdentifier
    }
}
