//
//  ToolCatalogPresentationTests.swift
//  osaurus
//
//  Contract tests for the plain-language Tools catalog presentation model:
//  exact exposure states must map onto exactly one user-facing status, and
//  every exposure source must have exactly one catalog section so each
//  registered tool has one home on the All tab.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ToolCatalogPresentationTests {

    // MARK: - Status mapping

    @Test
    func usableExposureStatesReadAsReady() {
        // Callable now, loadable on demand, and context-scoped (hidden by
        // agent scope / execution mode) tools all work without user action.
        for state in [ToolExposureState.exposed, .loadable, .hidden] {
            #expect(
                ToolCatalogPresentation.status(state: state, hasMissingSystemPermissions: false)
                    == .ready
            )
        }
    }

    @Test
    func globallyDisabledToolsReadAsOff() {
        #expect(
            ToolCatalogPresentation.status(state: .disabled, hasMissingSystemPermissions: false)
                == .off
        )
    }

    @Test
    func blockedAndUnavailableToolsNeedAttention() {
        for state in [ToolExposureState.blocked, .unavailable] {
            #expect(
                ToolCatalogPresentation.status(state: state, hasMissingSystemPermissions: false)
                    == .needsAttention
            )
        }
    }

    @Test
    func missingSystemPermissionAlwaysNeedsAttention() {
        // A missing macOS permission wins over any exposure state, including
        // "exposed": the tool cannot succeed until the user grants access.
        for state in ToolExposureState.allCases {
            #expect(
                ToolCatalogPresentation.status(state: state, hasMissingSystemPermissions: true)
                    == .needsAttention
            )
        }
        #expect(
            ToolCatalogPresentation.status(state: nil, hasMissingSystemPermissions: true)
                == .needsAttention
        )
    }

    @Test
    func unknownExposureDefaultsToReady() {
        // A tool without a diagnostic row (snapshot still loading) must not
        // scream "needs attention" at the user.
        #expect(
            ToolCatalogPresentation.status(state: nil, hasMissingSystemPermissions: false)
                == .ready
        )
    }

    @Test
    func everyExposureStateHasExactlyOneStatus() {
        // Exhaustiveness: adding a new exposure state must force a decision
        // about its user-facing category.
        for state in ToolExposureState.allCases {
            let status = ToolCatalogPresentation.status(
                state: state,
                hasMissingSystemPermissions: false
            )
            #expect(ToolCatalogStatus.allCases.contains(status))
        }
    }

    // MARK: - Section mapping

    @Test
    func everyExposureSourceHasExactlyOneSection() {
        for source in ToolExposureSource.allCases {
            let section = ToolCatalogPresentation.section(for: source)
            #expect(ToolCatalogSection.allCases.contains(section))
        }
    }

    @Test
    func shippedSourcesFoldIntoBuiltIn() {
        // Runtime-managed execution tools and native helpers ship with
        // Osaurus; the internal "runtime" category must not leak into the
        // default UI as its own group.
        for source in [ToolExposureSource.builtIn, .native, .runtime, .unknown] {
            #expect(ToolCatalogPresentation.section(for: source) == .builtIn)
        }
    }

    @Test
    func externalSourcesKeepTheirOwnSections() {
        #expect(ToolCatalogPresentation.section(for: .plugin) == .plugins)
        #expect(ToolCatalogPresentation.section(for: .mcpProvider) == .connections)
        #expect(ToolCatalogPresentation.section(for: .sandboxPlugin) == .custom)
    }

    // MARK: - Filters

    @Test
    func statusFilterAllMatchesEveryStatus() {
        for status in ToolCatalogStatus.allCases {
            #expect(ToolCatalogStatusFilter.all.matches(status))
        }
    }

    @Test
    func specificStatusFiltersMatchOnlyTheirStatus() {
        let pairs: [(ToolCatalogStatusFilter, ToolCatalogStatus)] = [
            (.ready, .ready),
            (.off, .off),
            (.needsAttention, .needsAttention),
        ]
        for (filter, status) in pairs {
            #expect(filter.matches(status))
            for other in ToolCatalogStatus.allCases where other != status {
                #expect(!filter.matches(other))
            }
        }
    }

    @Test
    func sourceFilterAllMatchesEverySection() {
        for section in ToolCatalogSection.allCases {
            #expect(ToolCatalogSourceFilter.all.matches(section))
        }
    }

    @Test
    func specificSourceFiltersMatchOnlyTheirSection() {
        let pairs: [(ToolCatalogSourceFilter, ToolCatalogSection)] = [
            (.builtIn, .builtIn),
            (.plugins, .plugins),
            (.connections, .connections),
            (.custom, .custom),
        ]
        for (filter, section) in pairs {
            #expect(filter.matches(section))
            for other in ToolCatalogSection.allCases where other != section {
                #expect(!filter.matches(other))
            }
        }
    }

    @Test
    func everySectionIsReachableThroughASourceFilter() {
        for section in ToolCatalogSection.allCases {
            #expect(
                ToolCatalogSourceFilter.allCases.contains { $0.section == section },
                "Section \(section.rawValue) must be selectable in the source filter."
            )
        }
    }

    @Test
    func everyStatusIsReachableThroughAStatusFilter() {
        for status in ToolCatalogStatus.allCases {
            #expect(
                ToolCatalogStatusFilter.allCases.contains { $0.status == status },
                "Status \(status.rawValue) must be selectable in the status filter."
            )
        }
    }

    // MARK: - Grouping contract (every diagnostic row has exactly one home)

    @Test
    func diagnosticRowsPartitionIntoExactlyOneSection() {
        let rows = ToolExposureSource.allCases.map { source in
            ToolExposureDiagnostic.Row(
                toolName: "tool_\(source.rawValue)",
                description: "fixture",
                source: source,
                state: .exposed,
                availability: ToolAvailability(
                    toolName: "tool_\(source.rawValue)",
                    runtime: nil,
                    groupName: nil,
                    reasonCodes: [.available],
                    detail: ""
                ),
                registered: true,
                globallyEnabled: true,
                indexedForSearch: true,
                searchableByCapabilitiesDiscover: true,
                searchReasonCodes: [.searchable],
                tokenEstimate: 1
            )
        }

        var seen: [String: ToolCatalogSection] = [:]
        for row in rows {
            let section = ToolCatalogPresentation.section(for: row.source)
            #expect(seen[row.toolName] == nil, "Row \(row.toolName) must map to a single section.")
            seen[row.toolName] = section
        }
        #expect(seen.count == rows.count)

        // Section counts must add back up to the row count — no row is
        // dropped and none is double-counted.
        let counts = Dictionary(grouping: rows) { ToolCatalogPresentation.section(for: $0.source) }
            .mapValues(\.count)
        #expect(counts.values.reduce(0, +) == rows.count)
    }

    // MARK: - Deep-link tab resolution

    @Test
    func legacyToolsSubTabRawValuesResolveToNewTabs() {
        #expect(ToolsTab.resolved(from: "Available") == .all)
        #expect(ToolsTab.resolved(from: "available") == .all)
        #expect(ToolsTab.resolved(from: "Remote") == .connections)
        #expect(ToolsTab.resolved(from: "remote") == .connections)
        #expect(ToolsTab.resolved(from: "Sandbox") == .custom)
        #expect(ToolsTab.resolved(from: "sandbox") == .custom)
        #expect(ToolsTab.resolved(from: "All") == .all)
        #expect(ToolsTab.resolved(from: "Connections") == .connections)
        #expect(ToolsTab.resolved(from: "Custom") == .custom)
        #expect(ToolsTab.resolved(from: "bogus") == nil)
    }
}
