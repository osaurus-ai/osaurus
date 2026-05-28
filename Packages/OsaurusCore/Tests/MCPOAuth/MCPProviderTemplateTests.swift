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

    @Test func everyConnectableURLIsHTTPS() {
        // Self-hosting templates intentionally ship an empty `url` because the
        // user supplies their own deployment endpoint. Skip them here; their
        // helpURL is validated separately.
        for template in MCPProviderTemplate.allTemplates where template.selfHostingHelpURL == nil {
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

    @Test func selfHostingTemplatesHaveHelpURL() {
        // Self-hosting templates can't drop the user into a one-tap connect flow
        // because there's no hosted endpoint, so they must point somewhere
        // useful (deploy docs, vendor README) over https.
        let selfHosting = MCPProviderTemplate.allTemplates.filter { $0.selfHostingHelpURL != nil }
        #expect(!selfHosting.isEmpty, "expected at least one self-hosting template (e.g. Google Workspace)")
        for template in selfHosting {
            let url = template.selfHostingHelpURL
            #expect(url?.scheme == "https", "Template \(template.id) selfHostingHelpURL must use https")
            #expect(url?.host?.isEmpty == false, "Template \(template.id) selfHostingHelpURL is missing a host")
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

    @Test func templatesAreAlphabeticallyOrdered() {
        // The picker renders this list in declaration order; keeping it sorted
        // gives a predictable scan order in the chip row.
        let displayNames = MCPProviderTemplate.allTemplates.map(\.displayName)
        let sorted = displayNames.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        #expect(displayNames == sorted, "Catalog is not alphabetically sorted by displayName")
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
