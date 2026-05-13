//
//  MCPProviderTemplateTests.swift
//  osaurusTests
//
//  Sanity tests for the well-known provider catalog. The catalog is hardcoded
//  Swift, so these tests catch regressions in copy/paste edits (duplicate IDs,
//  malformed URLs, missing auto-sign-in flag, broken alphabetical order) that
//  would otherwise only surface at runtime.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("MCP provider template catalog")
struct MCPProviderTemplateTests {
    @Test func catalogIsNonEmpty() {
        #expect(!MCPProviderTemplate.allTemplates.isEmpty)
    }

    @Test func idsAreUnique() {
        let ids = MCPProviderTemplate.allTemplates.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func displayNamesAreUnique() {
        let names = MCPProviderTemplate.allTemplates.map(\.displayName)
        #expect(Set(names).count == names.count)
    }

    @Test func everyURLIsHTTPS() {
        for template in MCPProviderTemplate.allTemplates {
            let url = URL(string: template.url)
            #expect(url != nil, "Template \(template.id) has unparseable URL: \(template.url)")
            #expect(
                url?.scheme == "https",
                "Template \(template.id) must use https (got \(url?.scheme ?? "nil"))"
            )
            #expect(
                url?.host?.isEmpty == false,
                "Template \(template.id) URL is missing a host"
            )
        }
    }

    @Test func oauthTemplatesAutoSignIn() {
        // The picker UX promises that tapping an OAuth chip immediately launches
        // sign-in. Any OAuth template that opted out would silently break that.
        for template in MCPProviderTemplate.allTemplates where template.authType == .oauth {
            #expect(
                template.autoSignInOnApply,
                "OAuth template \(template.id) must set autoSignInOnApply=true"
            )
        }
    }

    @Test func iconAndTaglineArePopulated() {
        for template in MCPProviderTemplate.allTemplates {
            #expect(!template.iconSystemName.isEmpty, "Template \(template.id) is missing an icon")
            #expect(!template.tagline.isEmpty, "Template \(template.id) is missing a tagline")
        }
    }

    @Test func templatesAreAlphabeticallyOrdered() {
        // The picker renders this list in declaration order; keeping it sorted
        // gives a predictable scan order in the chip row.
        let displayNames = MCPProviderTemplate.allTemplates.map(\.displayName)
        let sorted = displayNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        #expect(displayNames == sorted, "Catalog is not alphabetically sorted by displayName")
    }
}
