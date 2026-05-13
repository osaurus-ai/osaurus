//
//  MCPProviderTemplate.swift
//  osaurus
//
//  Hardcoded catalog of well-known remote MCP providers.
//
//  Templates are pure UI prefills — selecting one fills in the URL/auth fields of
//  the Add Provider sheet so the user doesn't have to look up an endpoint or pick
//  an auth scheme manually. The actual provider record stored on disk is identical
//  to one a user would build by hand, so removing or editing a template later
//  never affects already-saved providers.
//
//  Only providers whose remote MCP server supports either:
//    - OAuth 2.1 with Dynamic Client Registration (RFC 7591), or
//    - simple no-auth / static bearer-token connections,
//  are included. Servers that require manual `client_id`/`client_secret` issuance
//  (e.g. Asana V2) or pre-allowlisting of redirect URIs (e.g. Intercom) are
//  intentionally omitted because the auto-flow would silently fail for end users.
//

import Foundation

/// A pre-filled configuration for a well-known remote MCP server.
public struct MCPProviderTemplate: Identifiable, Sendable, Equatable {
    /// Stable slug used for both `Identifiable` conformance and selection state.
    public let id: String
    /// Human-friendly name shown in the picker chip and used as the default
    /// provider name when applied.
    public let displayName: String
    /// Canonical MCP endpoint. Verified against each vendor's published docs at
    /// the time of authoring; if a vendor changes URLs, the user can still tap
    /// the "Custom" chip and enter a new one without an app update.
    public let url: String
    /// Authentication strategy the server expects.
    public let authType: MCPProviderAuthType
    /// SF Symbol used as the chip icon. Vendor logos are intentionally avoided to
    /// keep the binary small and sidestep trademark/asset-licensing concerns.
    public let iconSystemName: String
    /// One-line description shown as a tooltip / accessibility hint.
    public let tagline: String
    /// When `true` and `authType == .oauth`, applying the template immediately
    /// kicks off the OAuth sign-in flow so the user only needs the single chip tap.
    public let autoSignInOnApply: Bool

    public init(
        id: String,
        displayName: String,
        url: String,
        authType: MCPProviderAuthType,
        iconSystemName: String,
        tagline: String,
        autoSignInOnApply: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.url = url
        self.authType = authType
        self.iconSystemName = iconSystemName
        self.tagline = tagline
        self.autoSignInOnApply = autoSignInOnApply
    }

    /// Catalog of well-known providers, alphabetically sorted by `displayName`.
    /// The UI relies on this order being stable across launches.
    public static let allTemplates: [MCPProviderTemplate] = [
        MCPProviderTemplate(
            id: "atlassian",
            displayName: "Atlassian",
            url: "https://mcp.atlassian.com/v1/mcp",
            authType: .oauth,
            iconSystemName: "shippingbox.fill",
            tagline: "Search and edit Jira, Confluence, and Compass content"
        ),
        MCPProviderTemplate(
            id: "cloudflare",
            displayName: "Cloudflare",
            url: "https://mcp.cloudflare.com/mcp",
            authType: .oauth,
            iconSystemName: "cloud.fill",
            tagline: "Manage your Cloudflare account, workers, and DNS"
        ),
        MCPProviderTemplate(
            id: "github",
            displayName: "GitHub",
            url: "https://api.githubcopilot.com/mcp/",
            authType: .oauth,
            iconSystemName: "chevron.left.forwardslash.chevron.right",
            tagline: "Browse repos, issues, and pull requests via Copilot"
        ),
        MCPProviderTemplate(
            id: "huggingface",
            displayName: "Hugging Face",
            url: "https://huggingface.co/mcp",
            authType: .oauth,
            iconSystemName: "face.smiling.fill",
            tagline: "Search models, datasets, papers, and Spaces"
        ),
        MCPProviderTemplate(
            id: "linear",
            displayName: "Linear",
            url: "https://mcp.linear.app/mcp",
            authType: .oauth,
            iconSystemName: "chart.bar.doc.horizontal.fill",
            tagline: "Read and update Linear issues, projects, and cycles"
        ),
        MCPProviderTemplate(
            id: "notion",
            displayName: "Notion",
            url: "https://mcp.notion.com/mcp",
            authType: .oauth,
            iconSystemName: "doc.text.fill",
            tagline: "Read and edit your Notion pages and databases"
        ),
        MCPProviderTemplate(
            id: "paypal",
            displayName: "PayPal",
            url: "https://mcp.paypal.com/mcp",
            authType: .oauth,
            iconSystemName: "p.circle.fill",
            tagline: "Query and manage PayPal payments and orders"
        ),
        MCPProviderTemplate(
            id: "sentry",
            displayName: "Sentry",
            url: "https://mcp.sentry.dev/mcp",
            authType: .oauth,
            iconSystemName: "exclamationmark.shield.fill",
            tagline: "Investigate Sentry issues, traces, and releases"
        ),
        MCPProviderTemplate(
            id: "stripe",
            displayName: "Stripe",
            url: "https://mcp.stripe.com",
            authType: .oauth,
            iconSystemName: "creditcard.fill",
            tagline: "Read and manage Stripe customers, charges, and subscriptions"
        ),
    ]
}
