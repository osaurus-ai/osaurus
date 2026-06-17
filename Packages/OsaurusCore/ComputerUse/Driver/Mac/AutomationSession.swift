//
//  AutomationSession.swift
//  OsaurusCore — Computer Use
//
//  Native macOS driver, brought in-core from osaurus-ai/osaurus-macos-use.
//  Side-effect-free telemetry holder for a title/narration/step the agent can
//  read back. Nothing in the input path consults this state.
//

import Foundation

final class AutomationSession: @unchecked Sendable {
    static let shared = AutomationSession()

    private let lock = NSLock()

    private var _isActive: Bool = false
    private var title: String = "Automation in progress"
    private var narration: String? = nil
    private var stepIndex: Int? = nil
    private var totalSteps: Int? = nil

    private init() {}

    // MARK: - State

    func isActive() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isActive
    }

    /// Snapshot used by the session reporting to surface current state.
    func currentState() -> (
        title: String, narration: String?, stepIndex: Int?, totalSteps: Int?,
        isActive: Bool, isCancelled: Bool
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (title, narration, stepIndex, totalSteps, _isActive, false)
    }

    // MARK: - Lifecycle

    func startSession(title: String, totalSteps: Int? = nil, narration: String? = nil) {
        lock.lock()
        _isActive = true
        self.title = title.isEmpty ? "Automation in progress" : title
        self.narration = narration
        self.stepIndex = nil
        self.totalSteps = totalSteps
        lock.unlock()
    }

    func updateSession(
        title: String? = nil,
        narration: String? = nil,
        stepIndex: Int? = nil,
        totalSteps: Int? = nil
    ) {
        lock.lock()
        if let title = title { self.title = title }
        if let narration = narration { self.narration = narration }
        if let stepIndex = stepIndex { self.stepIndex = stepIndex }
        if let totalSteps = totalSteps { self.totalSteps = totalSteps }
        lock.unlock()
    }

    func endSession(reason: String? = nil) {
        lock.lock()
        _isActive = false
        narration = nil
        stepIndex = nil
        totalSteps = nil
        title = "Automation in progress"
        lock.unlock()
        _ = reason
    }
}
