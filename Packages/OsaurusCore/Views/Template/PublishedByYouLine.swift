//
//  PublishedByYouLine.swift
//  osaurus
//
//  "3 published · 42 installs · Your author page" beside a library's
//  section title, for whichever kind of listing the page holds. Workflows
//  and Agents → Templates both show it once something is live.
//

import AppKit
import SwiftUI

struct PublishedByYouLine: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var registryRecords = WorkflowRegistryRecordStore.shared

    let kind: TemplateKind
    /// Search landing id for the line.
    let anchor: String

    /// "3 published · 42 installs"; nil while nothing of this kind is live.
    static func summary(liveCount: Int, installs: Int) -> String? {
        guard liveCount > 0 else { return nil }
        var parts = [liveCount == 1 ? L("1 published") : L("\(liveCount) published")]
        if installs > 0 { parts.append(installs == 1 ? L("1 install") : L("\(installs) installs")) }
        return parts.joined(separator: " · ")
    }

    private var live: [WorkflowRegistryRecord] { registryRecords.liveRecords(kind: kind) }

    /// The author's page on the registry, when the handle is known.
    private var authorPageURL: URL? {
        guard let handle = registryRecords.authorHandle(), handle.hasPrefix("@"),
            let base = live.first.flatMap({ WorkflowsRegistryAPIClient.origin(of: $0.url) })
        else { return nil }
        return base.appendingPathComponent("u").appendingPathComponent(String(handle.dropFirst()))
    }

    var body: some View {
        if let summary = Self.summary(liveCount: live.count, installs: registryRecords.totalInstalls(kind: kind)) {
            HStack(spacing: theme.space.s6) {
                Text(verbatim: summary)
                    .font(SettingsFont.smallLabel)
                    .foregroundColor(theme.text.secondary)
                if let authorPageURL {
                    Text(verbatim: "·").font(SettingsFont.rowDescription).foregroundColor(theme.text.tertiary)
                    Button {
                        NSWorkspace.shared.open(authorPageURL)
                    } label: {
                        Text("Your author page", bundle: .module)
                            .font(SettingsFont.smallLabel)
                            .foregroundColor(theme.text.link)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help(authorPageURL.absoluteString)
                }
            }
            .settingsLandingAnchor(anchor)
        }
    }
}
