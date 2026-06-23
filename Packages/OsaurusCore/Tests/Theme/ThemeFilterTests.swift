//
//  ThemeFilterTests.swift
//  OsaurusCoreTests
//
//  Covers the pure `themeMatches(_:filter:search:context:)` predicate that
//  drives the Themes gallery filter + search. Keeping the rules in a free
//  function lets us verify every branch without instantiating SwiftUI.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Theme gallery filtering")
struct ThemeFilterTests {
    // MARK: - Fixtures

    private func makeTheme(
        name: String,
        author: String = "User",
        builtIn: Bool = false,
        source: ThemeLibrarySource? = nil
    ) -> CustomTheme {
        var theme = CustomTheme.darkDefault
        theme.metadata.id = UUID()
        theme.metadata.name = name
        theme.metadata.author = author
        theme.isBuiltIn = builtIn
        if builtIn {
            theme.library = nil
        } else {
            theme.library = ThemeLibraryInfo(source: source ?? .local)
        }
        return theme
    }

    private func match(
        _ theme: CustomTheme,
        _ filter: ThemeFilter,
        search: String = "",
        context: ThemeFilterContext = .empty
    ) -> Bool {
        themeMatches(theme, filter: filter, search: search, context: context)
    }

    // MARK: - Source / built-in filters

    @Test("all filter matches every source")
    func allFilterMatchesEverything() {
        let themes = [
            makeTheme(name: "Dark", builtIn: true),
            makeTheme(name: "Mine", source: .local),
            makeTheme(name: "Grabbed", source: .imported),
            makeTheme(name: "Posted", source: .shared),
        ]
        for theme in themes {
            #expect(match(theme, .all))
        }
    }

    @Test("builtIn filter matches only built-in themes")
    func builtInFilterIsolatesBuiltIns() {
        #expect(match(makeTheme(name: "Dark", builtIn: true), .builtIn))
        #expect(!match(makeTheme(name: "Mine", source: .local), .builtIn))
        #expect(!match(makeTheme(name: "Grabbed", source: .imported), .builtIn))
        #expect(!match(makeTheme(name: "Posted", source: .shared), .builtIn))
    }

    @Test("local filter excludes built-in, imported, and shared")
    func localFilterIsolatesLocal() {
        #expect(match(makeTheme(name: "Mine", source: .local), .local))
        #expect(!match(makeTheme(name: "Dark", builtIn: true), .local))
        #expect(!match(makeTheme(name: "Grabbed", source: .imported), .local))
        #expect(!match(makeTheme(name: "Posted", source: .shared), .local))
    }

    @Test("imported filter isolates imported themes")
    func importedFilterIsolatesImported() {
        #expect(match(makeTheme(name: "Grabbed", source: .imported), .imported))
        #expect(!match(makeTheme(name: "Mine", source: .local), .imported))
        #expect(!match(makeTheme(name: "Dark", builtIn: true), .imported))
    }

    @Test("shared filter isolates shared themes")
    func sharedFilterIsolatesShared() {
        #expect(match(makeTheme(name: "Posted", source: .shared), .shared))
        #expect(!match(makeTheme(name: "Mine", source: .local), .shared))
        #expect(!match(makeTheme(name: "Grabbed", source: .imported), .shared))
    }

    // MARK: - Context-driven filters

    @Test("needsReview filter only matches themes in the review set")
    func needsReviewUsesContext() {
        let flagged = makeTheme(name: "Flagged", source: .local)
        let clean = makeTheme(name: "Clean", source: .local)
        let context = ThemeFilterContext(needsReviewIDs: [flagged.metadata.id], duplicateIDs: [])

        #expect(match(flagged, .needsReview, context: context))
        #expect(!match(clean, .needsReview, context: context))
        // With no context, nothing needs review.
        #expect(!match(flagged, .needsReview))
    }

    @Test("duplicates filter only matches themes in the duplicate set")
    func duplicatesUsesContext() {
        let dupe = makeTheme(name: "Twin", source: .imported)
        let unique = makeTheme(name: "Solo", source: .local)
        let context = ThemeFilterContext(needsReviewIDs: [], duplicateIDs: [dupe.metadata.id])

        #expect(match(dupe, .duplicates, context: context))
        #expect(!match(unique, .duplicates, context: context))
        #expect(!match(dupe, .duplicates))
    }

    // MARK: - Search

    @Test("search matches theme name case-insensitively")
    func searchMatchesName() {
        let theme = makeTheme(name: "Midnight Ocean", source: .local)
        #expect(match(theme, .all, search: "ocean"))
        #expect(match(theme, .all, search: "MIDNIGHT"))
        #expect(match(theme, .all, search: "  night oce  ".trimmingCharacters(in: .whitespaces)))
        #expect(!match(theme, .all, search: "sunrise"))
    }

    @Test("search matches author")
    func searchMatchesAuthor() {
        let theme = makeTheme(name: "Aurora", author: "Jane Designer", source: .local)
        #expect(match(theme, .all, search: "designer"))
        #expect(!match(theme, .all, search: "bob"))
    }

    @Test("blank search is ignored")
    func blankSearchIgnored() {
        let theme = makeTheme(name: "Aurora", source: .local)
        #expect(match(theme, .all, search: "   "))
    }

    @Test("search and filter must both pass")
    func searchCombinesWithFilter() {
        let imported = makeTheme(name: "Imported Sunset", source: .imported)
        let local = makeTheme(name: "Local Sunset", source: .local)

        // Matches the search but not the imported filter.
        #expect(!match(local, .imported, search: "sunset"))
        // Matches both.
        #expect(match(imported, .imported, search: "sunset"))
        // Matches the filter but not the search.
        #expect(!match(imported, .imported, search: "winter"))
    }
}
