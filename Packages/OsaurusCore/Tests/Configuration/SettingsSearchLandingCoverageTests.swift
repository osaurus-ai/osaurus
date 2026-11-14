//
//  SettingsSearchLandingCoverageTests.swift
//  osaurusTests
//
//  Every Settings search row must land somewhere: either it is a tab-level
//  row (opens the tab, no glow) or some view renders its id as a landing
//  anchor. A row whose id no view carries scrolls nowhere and glows nothing.
//

import Foundation
import Testing

@testable import OsaurusCore

struct SettingsSearchLandingCoverageTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func viewSources() throws -> String {
        var combined = ""
        for root in ["Views", "PrivacyFilter/Views", "Managers"] {
            let url = packageRoot.appendingPathComponent(root)
            guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)
            else { continue }
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                combined += try String(contentsOf: file, encoding: .utf8)
                combined += "\n"
            }
        }
        return combined
    }

    /// Ids a view can render: quoted literals, `"prefix.\(…)"` families,
    /// views that render the pending id itself when it has a known prefix
    /// (`pending.hasPrefix("agents.appleApps")`), and the Spawn editor's
    /// `anchorPrefix:` + `anchor("suffix")` pairs.
    static func renderedAnchors(
        in source: String
    ) -> (literals: Set<String>, prefixes: Set<String>, pendingFamilies: Set<String>) {
        var literals = Set(source.matches(of: /"([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)+)"/).map { String($0.1) })
        let prefixes = Set(source.matches(of: /"([A-Za-z0-9_]+(?:\.[A-Za-z0-9_]+)*\.)\\\(/).map { String($0.1) })
        let pendingFamilies = Set(
            source.matches(of: /pending\.hasPrefix\("([A-Za-z0-9_.]+)"\)/).map { String($0.1) })
        let spawnPrefixes = source.matches(of: /anchorPrefix: "([A-Za-z0-9_.]+)"/).map { String($0.1) }
        let spawnSuffixes = source.matches(of: /\banchor\("([A-Za-z0-9_]+)"\)/).map { String($0.1) }
        for prefix in spawnPrefixes {
            for suffix in spawnSuffixes { literals.insert("\(prefix).\(suffix)") }
        }
        return (literals, prefixes, pendingFamilies)
    }

    @Test func everyCatalogRowLandsOnARenderedAnchorOrItsTab() throws {
        let anchors = Self.renderedAnchors(in: try Self.viewSources())
        let unlanded = SettingsSearchIndex.entries.map(\.id).filter { id in
            if SettingsSearchIndex.tabLevelEntryIDs.contains(id) { return false }
            if anchors.literals.contains(id) { return false }
            if anchors.pendingFamilies.contains(where: { id.hasPrefix($0) }) { return false }
            return !anchors.prefixes.contains { prefix in
                id.hasPrefix(prefix) && !id.dropFirst(prefix.count).contains(".")
            }
        }
        #expect(
            unlanded.isEmpty,
            "Catalog rows with no rendered anchor: \(unlanded.sorted()). Put the id on the control (settingsLandingAnchor / anchorId) or list it in SettingsSearchIndex.tabLevelEntryIDs."
        )
    }
}
