//
//  LiveActivitySection.swift
//  osaurus
//
//  Read-only "what is the engine doing right now" card. Pulls the
//  aggregated `BatchEngine` snapshot from `MLXBatchAdapter` every two
//  seconds while the user is on the Settings tab.
//

import SwiftUI

struct LiveActivitySection: View {
    @State private var snapshot: BatchDiagnosticsSnapshot?
    @State private var refreshTimer: Timer?

    var body: some View {
        ServerSettingsCard(
            section: .liveActivity,
            status: .engineReady,
            blurb:
                "Aggregated BatchEngine readout across every model loaded right now. Refreshes every 2 seconds.",
            spacing: 16
        ) {
            BatchDiagnosticsView(snapshot: snapshot)
        }
        .onAppear { start() }
        .onDisappear { stop() }
    }

    private func start() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in refresh() }
        }
    }

    private func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        Task { @MainActor in
            snapshot = await MLXBatchAdapter.snapshotDiagnostics()
        }
    }
}
