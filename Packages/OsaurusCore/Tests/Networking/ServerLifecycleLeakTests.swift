//
//  ServerLifecycleLeakTests.swift
//  OsaurusCoreTests
//
//  Pins the NIO resource-lifecycle contract behind APPLE-MACOS-19T
//  (`kqueue(): Too many open files`, EMFILE): repeated server start/stop
//  cycles must not accumulate event-loop groups, threads, or descriptors.
//  All servers run on the process-shared `SharedEventLoopGroups`, so a stop
//  closes channels only — restart churn allocates nothing thread-shaped.
//

import Foundation
import NIOCore
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct ServerLifecycleLeakTests {

    /// Ten start/stop cycles on ephemeral ports must leave the process
    /// descriptor count where it started (small tolerance for unrelated
    /// background activity). Before the shared-group change, every cycle
    /// whose graceful drain timed out stranded a core-count thread group
    /// (~3 descriptors per thread) — nine of those was a fatal EMFILE.
    @Test
    func repeatedStartStopCyclesKeepDescriptorCountStable() async throws {
        // Warm-up: materialize the shared groups and any lazy singletons so
        // their one-time descriptor cost is excluded from the baseline.
        let warm = OsaurusServer()
        try await warm.start(.init(host: "127.0.0.1", port: 0), serverConfiguration: .default)
        #expect(await warm.boundPort() != nil)
        await warm.stop(gracefully: false)

        let baseline = try #require(SharedEventLoopGroups.openFileDescriptorCount())

        for _ in 0..<10 {
            let server = OsaurusServer()
            try await server.start(.init(host: "127.0.0.1", port: 0), serverConfiguration: .default)
            #expect(await server.boundPort() != nil)
            await server.stop(gracefully: false)
        }

        let after = try #require(SharedEventLoopGroups.openFileDescriptorCount())
        // Ten leaked per-start groups would add hundreds of descriptors;
        // allow a small delta for unrelated process activity.
        #expect(
            after <= baseline + 10,
            "descriptor count grew from \(baseline) to \(after) across 10 start/stop cycles"
        )
    }

    /// A stopped server must actually release its listening port state:
    /// binding, stopping, and rebinding the same server object must work,
    /// and `boundPort` must be nil while stopped.
    @Test
    func stopReleasesListenerAndAllowsRestart() async throws {
        let server = OsaurusServer()
        try await server.start(.init(host: "127.0.0.1", port: 0), serverConfiguration: .default)
        let firstPort = try #require(await server.boundPort())
        await server.stop(gracefully: false)
        #expect(await server.boundPort() == nil)

        // Rebind on the SAME port that was just released — proves the
        // listener descriptor is actually closed, not merely forgotten.
        try await server.start(
            .init(host: "127.0.0.1", port: firstPort), serverConfiguration: .default
        )
        #expect(await server.boundPort() == firstPort)
        await server.stop(gracefully: false)
    }
}
