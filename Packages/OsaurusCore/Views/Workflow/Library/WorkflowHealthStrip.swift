//
//  WorkflowHealthStrip.swift
//  osaurus
//
//  How the last few runs went, as a row of bars, oldest on the left. Only
//  runs that finished or failed count; a short history is padded with
//  empty slots on the left. A failed bar is shorter as well as red, so the
//  strip never relies on color alone.
//

import SwiftUI

enum WorkflowHealth {
    enum Bar: Equatable, Sendable {
        case empty
        case worked
        case failed
    }

    /// Settled outcomes, newest first: true when the run worked.
    static func bars(newestFirst outcomes: [Bool], count: Int) -> [Bar] {
        let shown = outcomes.prefix(count).reversed().map { $0 ? Bar.worked : Bar.failed }
        return Array(repeating: .empty, count: max(0, count - shown.count)) + shown
    }

    static func outcomes(_ runs: [EventRun]) -> [Bool] {
        runs.compactMap { run in
            switch run.status {
            case .succeeded: return true
            case .failed: return false
            default: return nil
            }
        }
    }

    /// Architect tests never count; a run stopped by the person neither.
    static func outcomes(_ runs: [WorkflowRun]) -> [Bool] {
        runs.filter { !$0.isTest }.compactMap { run in
            switch run.status {
            case .completed: return true
            case .failed, .needsSetup: return false
            case .running, .awaitingUser, .cancelled: return nil
            }
        }
    }

    /// One label for the whole strip.
    static func accessibilityLabel(_ bars: [Bar]) -> String {
        let settled = bars.filter { $0 != .empty }
        let failed = settled.filter { $0 == .failed }.count
        guard !settled.isEmpty else { return L("No runs yet") }
        if failed == 0 {
            return settled.count == 1 ? L("The last run worked") : L("Last \(settled.count) runs all worked")
        }
        if settled.count == 1 || (failed == 1 && settled.last == .failed) { return L("Last run failed") }
        return L("\(failed) of the last \(settled.count) runs failed")
    }

    /// How the last runs went, in one sentence.
    static func summary(_ bars: [Bar]) -> String? {
        let settled = bars.filter { $0 != .empty }
        let failed = settled.filter { $0 == .failed }.count
        guard !settled.isEmpty else { return nil }
        if failed == 0 {
            return settled.count == 1 ? L("The last run worked.") : L("The last \(settled.count) runs worked.")
        }
        if settled.count == 1 || (failed == 1 && settled.last == .failed) { return L("The last run failed.") }
        return L("\(failed) of the last \(settled.count) runs failed.")
    }

    /// Recent Runs' headline: runs going now come first.
    static func headline(_ bars: [Bar], running: Int) -> String? {
        if running == 1 { return L("Running now.") }
        if running > 1 { return L("\(running) running now.") }
        return summary(bars)
    }
}

