//
//  EvalPairedRunIsolation.swift
//  OsaurusCore
//
//  Public facade the eval harness uses to keep PAIRED model runs honest.
//
//  The context-optimization harness compares a baseline run against
//  candidate runs executed later in the SAME process (the model stays
//  warm between runs). That design silently broke pairing twice on a
//  live Bonsai Ternary lane (2026-07-24):
//
//  - Runtime warm state (resident model containers, KV/prefix caches,
//    batch-engine state) accumulates monotonically, so the baseline
//    always runs colder than the candidates that follow it.
//
//  `capture()` snapshots the ambient tool-schema state after bootstrap;
//  `reapply(_:)` re-pins it immediately before every paired run; and
//  `resetRuntime()` tears down resident models and in-memory caches so
//  each run pays the same cold start. Eval-only: nothing here is
//  reachable from production composition.
//

import Foundation

public enum EvalPairedRunIsolation {

    /// Reserved snapshot for future proven mutable schema inputs. Current
    /// built-in schemas are immutable, so runtime cold-state is the only
    /// paired-run reset required.
    public struct AmbientSnapshot: Sendable {
        public init() {}
    }

    /// Snapshot the ambient tool-schema state (call once, after the
    /// harness bootstrap settles).
    public static func capture() -> AmbientSnapshot {
        AmbientSnapshot()
    }

    /// Re-pin the ambient state captured at bootstrap so every paired
    /// run composes against the same tool schemas the baseline saw.
    public static func reapply(_: AmbientSnapshot) {}

    /// Tear down resident models and in-memory runtime caches so the
    /// next run loads and warms from the same cold state as the first.
    /// (Disk-L2 KV entries persist inside the run-isolated storage; both
    /// sides of a pair see them identically once runs start cold.)
    public static func resetRuntime() async {
        await ModelRuntime.shared.clearAll()
    }
}
