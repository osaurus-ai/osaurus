//
//  MemoryDiagnostics.swift
//  osaurus
//
//  Helpers powering the Memory > Diagnostics panel — kept out of
//  `MemoryService` so the actor stays focused on the live read/write
//  pipeline. Holds:
//
//   * `BufferProbeOutcome` — typed result of the synthetic buffer test
//     (replaces the previous string-prefix-matched "OK:" / "FAIL:"
//     scheme so the rendering layer doesn't have to parse text).
//   * `MemoryDiagnostics.runBufferProbe(...)` — orchestrates the probe
//     itself: snapshots state, calls `bufferTurn`, diffs telemetry,
//     attaches a `pending_signals` schema dump on `SQLITE_CONSTRAINT`
//     failures so the user (and us) can localise schema drift in one
//     click.
//

import Foundation

/// Structured outcome of the synthetic buffer probe.
public enum BufferProbeOutcome: Sendable {
    /// Probe inserted a row. Counts confirm the disk-side delta.
    case success(beforeCount: Int, afterCount: Int)

    /// Probe failed at a specific stage. `schemaDump` is non-nil when
    /// the failure looked like an `SQLITE_CONSTRAINT` and we were able
    /// to dump the actual `pending_signals` schema for comparison.
    case failure(reason: String, schemaDump: String?)
}

extension BufferProbeOutcome {
    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    /// Single-string rendering — used by the banner's body label and by
    /// the diagnostics summary one-liner. Multi-line when the failure
    /// path attached a schema dump.
    public var displayText: String {
        switch self {
        case .success(let before, let after):
            return
                L(
                    "OK: bufferTurn inserted a row (\(before) → \(after)). The buffer path is healthy. Run 'Distill pending' or wait for the debounce."
                )
        case .failure(let reason, let schemaDump):
            if let schemaDump {
                return
                    "FAIL: \(reason)\n\nactual pending_signals schema:\n\(schemaDump)"
            }
            return L("FAIL: \(reason)")
        }
    }
}

public enum MemoryDiagnostics {
    /// Run the synthetic buffer probe end-to-end:
    ///   1. snapshot `(allTimeSignals, telemetry)` before
    ///   2. `bufferTurn(...)` with a probe message under `Agent.defaultId`
    ///   3. snapshot after, diff the telemetry counters
    ///   4. classify the outcome (success / specific failure mode)
    ///   5. on `SQLITE_CONSTRAINT`, attach `pending_signals` schema dump
    public static func runBufferProbe() async -> BufferProbeOutcome {
        let probeAgentId = Agent.defaultId.uuidString
        let probeConvId = "diagnostic-probe-\(UUID().uuidString)"
        let probeMessage =
            "[memory diagnostics] probe message at \(ISO8601DateFormatter().string(from: Date()))"

        let beforeCount =
            (try? MemoryDatabase.shared.pendingSignalsSummary().allTimeSignals) ?? -1

        let configEnabled = await MainActor.run { MemoryConfigurationStore.load().enabled }
        let dbOpen = MemoryDatabase.shared.isOpen
        let lastOpenError = MemoryDatabase.shared.lastOpenErrorDescription
        let telemetryBefore = await MemoryService.shared.bufferTelemetry()

        await MemoryService.shared.bufferTurn(
            userMessage: probeMessage,
            assistantMessage: "[probe] no real assistant response",
            agentId: probeAgentId,
            conversationId: probeConvId,
            sessionDate: nil
        )

        let afterCount =
            (try? MemoryDatabase.shared.pendingSignalsSummary().allTimeSignals) ?? -1
        let telemetryAfter = await MemoryService.shared.bufferTelemetry()

        return classify(
            configEnabled: configEnabled,
            dbOpen: dbOpen,
            lastOpenError: lastOpenError,
            beforeCount: beforeCount,
            afterCount: afterCount,
            before: telemetryBefore,
            after: telemetryAfter
        )
    }

    /// Pure classification — extracted so it stays unit-testable and so
    /// the orchestration above reads as a flat snapshot/run/snapshot
    /// sequence.
    static func classify(
        configEnabled: Bool,
        dbOpen: Bool,
        lastOpenError: String? = nil,
        beforeCount: Int,
        afterCount: Int,
        before: BufferTurnTelemetry,
        after: BufferTurnTelemetry
    ) -> BufferProbeOutcome {
        let deltaInsertFailures = after.insertFailures - before.insertFailures
        let deltaInsertSuccesses = after.insertSuccesses - before.insertSuccesses
        let deltaEmptyMsg = after.earlyReturnsEmptyMessage - before.earlyReturnsEmptyMessage
        let deltaDisabled = after.earlyReturnsDisabled - before.earlyReturnsDisabled
        let deltaAttempts = after.attempts - before.attempts

        guard configEnabled else {
            return .failure(
                reason:
                    "memory globally disabled (config.enabled = false). Toggle the Status switch in Configuration.",
                schemaDump: nil
            )
        }
        guard dbOpen else {
            let detail = lastOpenError.map { " Last open error: \($0)" } ?? ""
            return .failure(
                reason:
                    "memory database is closed. Restart the app and check Console for SQLCipher errors.\(detail)",
                schemaDump: nil
            )
        }
        if afterCount > beforeCount && deltaInsertSuccesses > 0 {
            return .success(beforeCount: beforeCount, afterCount: afterCount)
        }
        if deltaInsertSuccesses > 0 && afterCount == beforeCount {
            return .failure(
                reason:
                    "telemetry says insert succeeded but row count unchanged (\(beforeCount) → \(afterCount)). The INSERT is being silently rolled back — likely a corrupt/locked DB or a hot-reload of the schema. Quit and relaunch.",
                schemaDump: nil
            )
        }
        if deltaInsertFailures > 0, let err = after.lastError {
            let lower = err.lowercased()
            let attachSchema =
                lower.contains("sqlite_constraint") || lower.contains("step=19")
            let schemaDump = attachSchema ? schemaDumpWithContext() : nil
            return .failure(
                reason: "bufferTurn threw on insert. \(err)",
                schemaDump: schemaDump
            )
        }
        if deltaDisabled > 0 {
            return .failure(
                reason: "bufferTurn returned early because config.enabled was read as false.",
                schemaDump: nil
            )
        }
        if deltaEmptyMsg > 0 {
            return .failure(
                reason:
                    "bufferTurn rejected the probe as empty — should not happen for the synthetic probe; check the trim guard.",
                schemaDump: nil
            )
        }
        if deltaAttempts == 0 {
            return .failure(
                reason:
                    "telemetry recorded zero attempts — bufferTurn never executed (actor blocked? probe task cancelled?).",
                schemaDump: nil
            )
        }
        return .failure(
            reason:
                "bufferTurn returned without inserting and without recording a known reason. Check Console for memory_service logs.",
            schemaDump: nil
        )
    }

    /// Schema dump plus the surrounding facts every constraint-failure
    /// report needs: the database's `user_version` vs what this build
    /// expects, the app version, and the last open/migration error. A
    /// single screenshot then distinguishes "hasn't updated yet",
    /// "migration keeps failing", and "schema drifted some other way".
    static func schemaDumpWithContext() -> String {
        var lines = [MemoryDatabase.shared.tableSchemaDescription(table: "pending_signals")]
        let userVersion =
            MemoryDatabase.shared.schemaUserVersion().map(String.init) ?? "unknown"
        lines.append("")
        lines.append(
            "schema user_version: \(userVersion) (this build expects \(MemoryDatabase.expectedSchemaVersion))"
        )
        let appVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "unknown"
        lines.append("app version: \(appVersion)")
        if let openError = MemoryDatabase.shared.lastOpenErrorDescription {
            lines.append("last open/migration error: \(openError)")
        }
        return lines.joined(separator: "\n")
    }
}
