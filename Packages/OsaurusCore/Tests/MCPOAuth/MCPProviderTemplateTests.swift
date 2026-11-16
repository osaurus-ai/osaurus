//
//  MCPProviderTemplateTests.swift
//  osaurusTests
//
//  Sanity tests for the well-known provider catalog. The catalog is hardcoded
//  Swift, so these tests catch regressions in copy/paste edits (duplicate IDs,
//  malformed URLs, missing auto-sign-in flag, broken category order) that
//  would otherwise only surface at runtime.
//

import AppKit
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

    @Test func bearerTokenTemplatesHaveAPIKeyHelpURL() {
        // Without a help link, a user lands on the API-key screen with no
        // guidance on where to obtain a key — silently broken UX.
        for template in MCPProviderTemplate.allTemplates where template.authType == .bearerToken {
            let url = template.apiKeyHelpURL
            #expect(
                url != nil,
                "Bearer-token template \(template.id) must ship an apiKeyHelpURL"
            )
            #expect(url?.scheme == "https", "Template \(template.id) apiKeyHelpURL must use https")
            #expect(url?.host?.isEmpty == false, "Template \(template.id) apiKeyHelpURL is missing a host")
        }
    }

    @Test func iconAndTaglineArePopulated() {
        for template in MCPProviderTemplate.allTemplates {
            #expect(!template.iconSystemName.isEmpty, "Template \(template.id) is missing an icon")
            #expect(!template.tagline.isEmpty, "Template \(template.id) is missing a tagline")
        }
    }

    @Test func iconsAreRealSFSymbols() {
        // A misspelled symbol renders as an empty tile with no build error.
        for template in MCPProviderTemplate.allTemplates {
            #expect(
                NSImage(systemSymbolName: template.iconSystemName, accessibilityDescription: nil) != nil,
                "Template \(template.id) uses unknown SF Symbol \(template.iconSystemName)"
            )
        }
    }

    @Test func templatesAreOrderedByCategoryThenName() {
        // Professional domains come first; within a category the directory
        // scans alphabetically.
        let templates = MCPProviderTemplate.allTemplates
        for (lhs, rhs) in zip(templates, templates.dropFirst()) {
            let lhsRank = MCPProviderCategory.allCases.firstIndex(of: lhs.category)!
            let rhsRank = MCPProviderCategory.allCases.firstIndex(of: rhs.category)!
            #expect(lhsRank <= rhsRank, "\(lhs.id) (\(lhs.category)) sorts after \(rhs.id) (\(rhs.category))")
            if lhsRank == rhsRank {
                #expect(
                    lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending,
                    "\(lhs.displayName) and \(rhs.displayName) are out of order"
                )
            }
        }
        #expect(templates.first?.category == .legal)
    }

    @Test func everyCategoryHasTemplates() {
        for category in MCPProviderCategory.allCases {
            #expect(
                MCPProviderTemplate.allTemplates.contains { $0.category == category },
                "Category \(category) is empty"
            )
        }
    }

    @Test func metadataDocumentOnlyTemplatesAreHiddenUntilPublished() {
        let cimdOnly = MCPProviderTemplate.allTemplates.filter(\.requiresClientMetadataDocument)
        #expect(!cimdOnly.isEmpty)
        for template in cimdOnly {
            #expect(template.authType == .oauth)
            #expect(!template.requiresManualOAuthCredentials)
        }
        let hidden = MCPProviderTemplate.available(metadataDocumentPublished: false)
        #expect(hidden.allSatisfy { !$0.requiresClientMetadataDocument })
        #expect(MCPProviderTemplate.available(metadataDocumentPublished: true) == MCPProviderTemplate.allTemplates)
    }

    @Test func directorySearchMatchesCategoryAndFiltersByCategory() {
        let legal = MCPProviderDirectoryView.templates(matching: "legal")
        #expect(legal.contains { $0.id == "courtlistener" })
        let health = MCPProviderDirectoryView.templates(matching: "", category: .healthcare)
        #expect(!health.isEmpty)
        #expect(health.allSatisfy { $0.category == .healthcare })
        let hiddenByDefault = MCPProviderDirectoryView.templates(matching: "MyCase")
        #expect(hiddenByDefault.isEmpty)
        let shownWhenPublished = MCPProviderDirectoryView.templates(
            matching: "MyCase", metadataDocumentPublished: true
        )
        #expect(shownWhenPublished.map(\.id) == ["mycase"])
    }

    @Test func correctedEndpointsArePinned() {
        let byId = Dictionary(uniqueKeysWithValues: MCPProviderTemplate.allTemplates.map { ($0.id, $0) })
        // `/mcp` on these hosts returns 404.
        #expect(byId["vercel"]?.url == "https://mcp.vercel.com/")
        // Atlassian v2 and Zapier publish OAuth discovery with dynamic
        // client registration, so they no longer need an API key.
        #expect(byId["atlassian"]?.url == "https://mcp.atlassian.com/v2/mcp")
        #expect(byId["atlassian"]?.authType == .oauth)
        #expect(byId["zapier"]?.authType == .oauth)
        // Stack Overflow publishes no OAuth discovery metadata, and Google's
        // hosted servers replace the self-hosted Workspace template.
        #expect(byId["stackoverflow"] == nil)
        #expect(byId["google_workspace"] == nil)
        #expect(byId["google_drive"]?.requiresManualOAuthCredentials == true)
        // Gusto serves MCP at the bare host; `/mcp` returns 404.
        #expect(byId["gusto"]?.url == "https://mcp.api.gusto.com")
        // Dropbox, Gusto, and QuickBooks publish dynamic client registration.
        // Harvey and Microsoft Work IQ only accept clients they or the tenant
        // admin issue, so they need the manual credentials form.
        for id in ["dropbox", "dropbox_dash", "gusto", "quickbooks"] {
            #expect(byId[id]?.authType == .oauth, "\(id)")
            #expect(byId[id]?.requiresManualOAuthCredentials == false, "\(id)")
        }
        for id in ["harvey", "microsoft_365"] {
            #expect(byId[id]?.requiresManualOAuthCredentials == true, "\(id)")
            #expect(byId[id]?.requiresSubscription == true, "\(id)")
        }
        #expect(byId["everlaw"] == nil)
        #expect(byId["clio"] == nil)
    }

    @Test func confidentialOAuthTemplatesAreFullyConfigured() {
        // OAuth templates that flag `requiresManualOAuthCredentials` must
        // ship both a docs link AND a fixed loopback port — without those,
        // the connect-known confidential-client form has nothing useful to
        // render and the redirect URI it surfaces would be `127.0.0.1:0`.
        let confidential = MCPProviderTemplate.allTemplates.filter {
            $0.requiresManualOAuthCredentials
        }
        #expect(
            !confidential.isEmpty,
            "expected at least one confidential-client OAuth template (HubSpot)"
        )
        #expect(
            Set(confidential.compactMap(\.oauthFixedLoopbackPort)) == [MCPProviderTemplate.manualOAuthLoopbackPort],
            "manual OAuth templates should share one redirect URI"
        )
        for template in confidential {
            #expect(
                template.authType == .oauth,
                "Template \(template.id) flags requiresManualOAuthCredentials but isn't .oauth"
            )
            let helpURL = template.oauthSetupHelpURL
            #expect(
                helpURL != nil,
                "Template \(template.id) requires manual OAuth credentials but has no oauthSetupHelpURL"
            )
            #expect(helpURL?.scheme == "https", "Template \(template.id) oauthSetupHelpURL must use https")
            #expect(helpURL?.host?.isEmpty == false, "Template \(template.id) oauthSetupHelpURL is missing a host")
            #expect(
                (template.oauthFixedLoopbackPort ?? 0) > 1024,
                "Template \(template.id) must pin oauthFixedLoopbackPort to a non-zero unprivileged port"
            )
        }
    }

    @Test func hubspotIsConfidentialOAuthOnCanonicalHost() {
        // HubSpot is the canonical confidential-client OAuth template:
        //   - URL must point at mcp.hubspot.com (the documented endpoint).
        //     The `app.hubspot.com/mcp/v1/http` alias tripped users into
        //     pasting Private App PATs, which mcp.hubspot.com rejects.
        //   - authType must be `.oauth` so the connect-known sheet renders
        //     the OAuth flow instead of the API-key screen.
        //   - requiresManualOAuthCredentials must be true because HubSpot's
        //     ASM publishes no `registration_endpoint`.
        let hubspot = MCPProviderTemplate.allTemplates.first { $0.id == "hubspot" }
        #expect(hubspot != nil)
        #expect(hubspot?.authType == .oauth)
        #expect(hubspot?.requiresManualOAuthCredentials == true)
        #expect(hubspot?.url == "https://mcp.hubspot.com")
        #expect(hubspot?.oauthFixedLoopbackPort != nil)
        #expect(hubspot?.apiKeyHelpURL == nil)
    }
}
