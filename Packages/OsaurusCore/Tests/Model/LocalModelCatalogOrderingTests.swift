//
//  LocalModelCatalogOrderingTests.swift
//  osaurusTests
//
//  The Local Models table's scope chips, search, header sorts and narrow
//  column hiding, shared by every model kind.
//

import Foundation
import Testing

@testable import OsaurusCore

struct LocalModelCatalogOrderingTests {

    private func item(
        _ id: String,
        status: LocalModelCatalogItem.Status = .available,
        isTopPick: Bool = false,
        fit: ModelCompatibility? = nil,
        memoryGB: Double? = nil,
        sizeBytes: Int64? = nil,
        releasedAt: Date? = nil,
        haystack: String = ""
    ) -> LocalModelCatalogItem {
        var item = LocalModelCatalogItem(id: id, name: id, subtitle: "", icon: "cube", status: status)
        item.isTopPick = isTopPick
        item.fit = fit
        item.memoryGB = memoryGB
        item.sizeBytes = sizeBytes
        item.releasedAt = releasedAt
        item.searchHaystack = haystack
        return item
    }

    private func ids(_ items: [LocalModelCatalogItem]) -> [String] { items.map(\.id) }

    // MARK: - Scope

    @Test func scopesSplitOnThisMacFromAvailable() {
        let items = [
            item("a"),
            item("b", status: .installed),
            item("c", status: .inProgress(progress: 0.3, detail: nil, isPaused: true)),
            item("d", status: .failed("boom")),
        ]
        #expect(ids(LocalModelCatalogOrdering.arrange(items, scope: .onThisMac, query: "", sort: nil)) == ["c", "b"])
        #expect(ids(LocalModelCatalogOrdering.arrange(items, scope: .available, query: "", sort: nil)) == ["a", "d"])
        #expect(LocalModelCatalogOrdering.arrange(items, scope: .all, query: "", sort: nil).count == 4)
    }

    // MARK: - Default order

    @Test func defaultOrderPutsDownloadsThenInstalledThenTopPicks() {
        let items = [
            item("plain-newest"),
            item("pick", isTopPick: true),
            item("installed", status: .installed),
            item("plain-older"),
            item("downloading", status: .inProgress(progress: 0.5, detail: nil, isPaused: false)),
        ]
        #expect(
            ids(LocalModelCatalogOrdering.sorted(items, by: nil))
                == ["downloading", "installed", "pick", "plain-newest", "plain-older"]
        )
    }

    // MARK: - Search

    @Test func searchRequiresEveryTerm() {
        let items = [
            item("qwen", haystack: "qwen 3.6 27b vision mxfp4"),
            item("gemma", haystack: "gemma 4 12b mxfp4"),
        ]
        #expect(ids(LocalModelCatalogOrdering.search(items, query: "MXFP4")) == ["qwen", "gemma"])
        #expect(ids(LocalModelCatalogOrdering.search(items, query: "mxfp4 vision")) == ["qwen"])
        #expect(LocalModelCatalogOrdering.search(items, query: "llama").isEmpty)
        #expect(LocalModelCatalogOrdering.search(items, query: "   ").count == 2)
    }

    @Test func searchFallsBackToTheName() {
        let items = [item("Parakeet"), item("Whisper")]
        #expect(ids(LocalModelCatalogOrdering.search(items, query: "para")) == ["Parakeet"])
    }

    // MARK: - Header sorts

    @Test func sizeSortPutsMissingValuesLastInBothDirections() {
        let items = [
            item("unknown"),
            item("big", sizeBytes: 30),
            item("small", sizeBytes: 10),
        ]
        let ascending = SettingsDataTableSort<LocalModelSortKey>(key: .size, ascending: true)
        let descending = SettingsDataTableSort<LocalModelSortKey>(key: .size, ascending: false)
        #expect(ids(LocalModelCatalogOrdering.sorted(items, by: ascending)) == ["small", "big", "unknown"])
        #expect(ids(LocalModelCatalogOrdering.sorted(items, by: descending)) == ["big", "small", "unknown"])
    }

    @Test func fitSortRanksRunsWellBeforeTooLarge() {
        let items = [
            item("huge", fit: .tooLarge),
            item("tight", fit: .tight),
            item("fine", fit: .compatible),
            item("mystery", fit: .unknown),
        ]
        let sort = SettingsDataTableSort<LocalModelSortKey>(key: .fit, ascending: true)
        #expect(ids(LocalModelCatalogOrdering.sorted(items, by: sort)) == ["fine", "tight", "huge", "mystery"])
    }

    @Test func tiesBreakByName() {
        let items = [item("b", memoryGB: 8), item("a", memoryGB: 8), item("c", memoryGB: 4)]
        let sort = SettingsDataTableSort<LocalModelSortKey>(key: .memory, ascending: true)
        #expect(ids(LocalModelCatalogOrdering.sorted(items, by: sort)) == ["c", "a", "b"])
    }

    @Test func headerClicksCycleThroughDirectionsBackToDefault() {
        let first = SettingsDataTableSort<LocalModelSortKey>.next(after: nil, key: .released, initialAscending: false)
        #expect(first == SettingsDataTableSort(key: .released, ascending: false))
        let second = SettingsDataTableSort<LocalModelSortKey>.next(after: first, key: .released, initialAscending: false)
        #expect(second == SettingsDataTableSort(key: .released, ascending: true))
        #expect(SettingsDataTableSort<LocalModelSortKey>.next(after: second, key: .released, initialAscending: false) == nil)
        // Another column starts fresh.
        let other = SettingsDataTableSort<LocalModelSortKey>.next(after: second, key: .size, initialAscending: true)
        #expect(other == SettingsDataTableSort(key: .size, ascending: true))
    }

    // MARK: - Column hiding

    @Test func narrowTablesDropReleasedThenMemoryThenSize() {
        let columns = LocalModelColumn.allCases.map(\.tableColumn)
        func visible(_ width: CGFloat) -> [String] {
            SettingsDataTableLayout.visibleColumns(columns, width: width, spacing: 8, insets: 24).map(\.id)
        }
        #expect(visible(1_000) == ["model", "fit", "memory", "size", "released", "status"])
        #expect(visible(700) == ["model", "fit", "memory", "size", "status"])
        #expect(visible(600) == ["model", "fit", "size", "status"])
        #expect(visible(520) == ["model", "fit", "status"])
        // Model and status never hide, even when they overflow.
        #expect(visible(200) == ["model", "status"])
    }

    @Test func zeroWidthKeepsEveryColumn() {
        let columns = LocalModelColumn.allCases.map(\.tableColumn)
        #expect(SettingsDataTableLayout.visibleColumns(columns, width: 0, spacing: 8, insets: 24).count == 6)
    }

    // MARK: - Adapters

    @Test @MainActor func speechSizesParseFromCatalogLabels() {
        #expect(SpeechCatalogSource.approximateBytes("~600 MB") == 600_000_000)
        #expect(SpeechCatalogSource.approximateBytes("1.2 GB") == 1_200_000_000)
        #expect(SpeechCatalogSource.approximateBytes("big") == nil)
    }
}
