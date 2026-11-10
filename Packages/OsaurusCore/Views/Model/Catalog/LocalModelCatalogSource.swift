//
//  LocalModelCatalogSource.swift
//  osaurus
//
//  Feeds one model kind into the Local Models table. Subclasses wrap a
//  kind's existing managers (they never change them) and publish rows in
//  that kind's preferred order; the page applies scope, search and sort.
//

import Combine
import SwiftUI

@MainActor
class LocalModelCatalogSource: ObservableObject {
    /// A sheet a row action opens (Image's generate panel).
    struct SheetRequest: Identifiable {
        let id: String
        let content: () -> AnyView
    }

    let kind: LocalModelKind

    /// Every row of the kind, installed and available, in the source's order.
    @Published var items: [LocalModelCatalogItem] = []
    /// True while the first batch of rows is still loading.
    @Published var isLoading = false
    @Published var sheetRequest: SheetRequest?

    init(kind: LocalModelKind) {
        self.kind = kind
    }

    /// The columns this kind has real values for, in `LocalModelColumn` order.
    var columns: [LocalModelColumn] { [.model, .size, .status] }

    /// Language's filter popover; other kinds search only.
    var supportsFilters: Bool { false }

    /// Kinds whose Add Model imports a Hugging Face repo.
    var supportsImport: Bool { false }

    /// True when `setQuery` already narrows `items` (remote search), so the
    /// page must not filter them again.
    var searchesItself: Bool { false }

    /// Already-localized header subtitle; nil shows the kind's description.
    var headerSummary: String? {
        let installed = items.filter { $0.status == .installed }.count
        guard installed > 0 else { return nil }
        return L("\(installed) on this Mac")
    }

    /// Notice above the table (legacy files to clean up, token nudges).
    func banner(scope: LocalModelCatalogScope) -> AnyView? { nil }

    /// Catalog key shown under the table.
    var footnote: String? { nil }

    /// Settings-search anchor that lands on this kind's table.
    var landingAnchorId: String? { nil }

    /// Header refresh for catalogs fetched from outside the app. Catalog key.
    var refreshHelp: String? { nil }
    var isRefreshing: Bool { false }
    func refresh() {}

    /// Start observing managers and loading. Called when the kind's page
    /// appears; safe to call more than once.
    func activate() {}

    func setQuery(_ query: String) {}
}

/// One source per kind, created on first use and kept for the window's life
/// so switching tabs does not reload a catalog.
@MainActor
final class LocalModelCatalogSources: ObservableObject {
    private var sources: [LocalModelKind: LocalModelCatalogSource] = [:]

    func source(for kind: LocalModelKind) -> LocalModelCatalogSource {
        if let existing = sources[kind] { return existing }
        let created: LocalModelCatalogSource
        switch kind {
        case .language: created = LanguageCatalogSource()
        case .image: created = ImageCatalogSource()
        case .speech: created = SpeechCatalogSource()
        case .detection: created = PrivacyDetectionCatalogSource()
        case .appleScript: created = AppleScriptCatalogSource()
        }
        sources[kind] = created
        return created
    }
}
