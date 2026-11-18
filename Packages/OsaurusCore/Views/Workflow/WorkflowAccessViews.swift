//
//  WorkflowAccessViews.swift
//  osaurus
//
//  What a workflow touches, in the same words everywhere: the "Your
//  files" rows (Reads / Writes / Deletes), the one line a listing shows,
//  and the "your files in → sandbox → results out" strip.
//

import AppKit
import SwiftUI

extension WorkflowAccessScope {
    /// Where the workflow's work happens, in the order a person reads it.
    var places: [Place] {
        var places: [Place] = []
        if !sources.isEmpty || !hostReach.isEmpty || mayAskForMoreFolders { places.append(.mac) }
        if runsInSandbox { places.append(.sandbox) }
        return places
    }
}

/// Reads / Writes / Deletes, plus Replaces and Also uses when they apply.
struct WorkflowAccessRows: View {
    let scope: WorkflowAccessScope

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s6) {
            ForEach(scope.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: theme.space.s8) {
                    Image(systemName: row.systemImage)
                        .glyphSize(.footnote)
                        .foregroundColor(tint(row.verb))
                        .frame(width: theme.space.s16)
                    Text(verbatim: row.title)
                        .textStyle(.bodySmall, weight: 600)
                        .foregroundColor(theme.text.primary)
                    Text(verbatim: row.value)
                        .textStyle(.bodySmall)
                        .foregroundColor(theme.text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !scope.places.isEmpty {
                WorkflowAccessPlaces(places: scope.places)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func tint(_ verb: WorkflowAccessScope.Row.Verb) -> Color {
        switch verb {
        case .reads, .writes, .deletes: return theme.text.secondary
        case .replaces: return theme.status.warning.foreground
        case .alsoUses: return theme.status.error.foreground
        }
    }
}

/// "Your Mac · Sandbox" with their icons.
struct WorkflowAccessPlaces: View {
    let places: [WorkflowAccessScope.Place]

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space.s4) {
            ForEach(places, id: \.self) { place in
                StatusChip(place.title, tone: .neutral, icon: place.systemImage)
            }
        }
    }
}

/// The one line a listing, install sheet, or save card shows, with the
/// places it happens.
struct WorkflowAccessLine: View {
    let scope: WorkflowAccessScope

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: theme.space.s6) {
            ForEach(scope.places, id: \.self) { place in
                Image(systemName: place.systemImage)
                    .glyphSize(.footnote)
                    .foregroundColor(theme.text.tertiary)
                    .help(place.title)
                    .accessibilityLabel(Text(verbatim: place.title))
            }
            if scope.places.isEmpty {
                Image(systemName: "lock")
                    .glyphSize(.footnote)
                    .foregroundColor(theme.text.tertiary)
            }
            Text(verbatim: scope.oneLine)
                .textStyle(.caption)
                .foregroundColor(theme.text.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(scope.architectSentence)
    }
}

/// What a run created or replaced on this Mac: "Created 12 PNGs in
/// dinos/png", each with Show in Finder.
struct WorkflowHostWritesSummary: View {
    let summaries: [WorkflowHostWrite.Summary]

    @Environment(\.theme) private var theme

    init(run: WorkflowRun, definition: WorkflowDefinition?, boundFolders: [String: String]) {
        let roots =
            definition.map {
                WorkflowAccessScope.derive($0).resolved(input: run.input, dialogOutputs: [:], boundFolders: boundFolders)
                    .map(\.url)
            } ?? []
        summaries = WorkflowHostWrite.summaries(run.hostWrites, roots: roots)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.space.s8) {
            ForEach(summaries) { summary in
                HStack(spacing: theme.space.s8) {
                    Image(systemName: WorkflowAccessScope.Place.mac.systemImage)
                        .glyphSize(.footnote)
                        .foregroundColor(theme.text.secondary)
                        .accessibilityHidden(true)
                    Text(verbatim: summary.text)
                        .textStyle(.bodySmall)
                        .foregroundColor(theme.text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(summary.folder.path)
                    Spacer(minLength: theme.space.s8)
                    SettingsButton(.secondary, "Show in Finder", size: .compact) {
                        NSWorkspace.shared.activateFileViewerSelecting(summary.files)
                    }
                }
            }
        }
    }
}

/// Your files in → Sandbox → Results out.
struct WorkflowAccessStrip: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: theme.space.s8) {
            step("laptopcomputer", L("Your files in"))
            arrow
            step(WorkflowAccessScope.Place.sandbox.systemImage, L("Work in the sandbox"))
            arrow
            step("tray.and.arrow.down", L("Results out"))
        }
        .help(L("Workflows read the folders you choose, do their work in the sandbox, and save results where they say. Each one lists what it reads and saves before you run it."))
        .accessibilityElement(children: .combine)
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .glyphSize(.micro)
            .foregroundColor(theme.text.tertiary)
            .accessibilityHidden(true)
    }

    private func step(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: theme.space.s4) {
            Image(systemName: symbol)
                .glyphSize(.footnote)
                .foregroundColor(theme.text.secondary)
            Text(verbatim: title)
                .textStyle(.caption)
                .foregroundColor(theme.text.secondary)
        }
    }
}
