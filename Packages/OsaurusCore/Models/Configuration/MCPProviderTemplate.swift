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
//  Four template kinds:
//
//  1. **OAuth+DCR** (`authType == .oauth`, `requiresManualOAuthCredentials == false`)
//     The default. Tap a card and the connect-known screen runs the full
//     RFC 7591 dynamic-client-registration sign-in flow against the vendor.
//     Includes Linear, Notion, Vercel, Supabase, Cloudflare, etc.
//
//  2. **OAuth without DCR** (`authType == .oauth`, `requiresManualOAuthCredentials == true`)
//     Vendors whose remote MCP requires confidential-client OAuth and does not
//     publish a `registration_endpoint`, so the user must register an OAuth
//     app in the vendor's developer portal and paste the resulting client_id
//     + client_secret. `oauthFixedLoopbackPort` pins the loopback redirect URI
//     so the user can register it once with the vendor. Currently HubSpot's
//     MCP Auth Apps.
//
//  3. **Bearer-token / API-key** (`authType == .bearerToken`, `apiKeyHelpURL != nil`)
//     Two flavours, all routed through the same connect-known API-key screen:
//       - Vendors that issue dashboard-generated personal API keys (Zapier).
//       - Vendors whose remote MCP supports OAuth in principle but does *not*
//         publish RFC 9728 PRM / RFC 7591 DCR, so the spec-compliant auto-flow
//         can never bootstrap a client. Currently GitHub Copilot MCP and
//         Atlassian Rovo MCP — both accept a personal access token / API key
//         as a documented bearer-auth fallback.
//
//  4. **Self-hosting** (`selfHostingHelpURL != nil`)
//     For services that don't ship a hosted MCP at all — currently just Google
//     Workspace. Tapping opens the help URL externally and routes the sheet to
//     the Custom form so the user can paste their own deployed endpoint.
//
//  Skipped on purpose:
//    - Servers requiring manual `client_id`/`client_secret` issuance with no
//      bearer-token fallback (Asana V2, Intercom, Plaid).
//    - Multi-step API-key providers needing GCP project + IAM setup
//      (Google BigQuery, Maps, GKE). Bigger UX than this catalog supports today.
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
    /// the "Custom" chip and enter a new one without an app update. Empty for
    /// self-hosting templates because the URL belongs to the user's deployment.
    public let url: String
    /// Authentication strategy the server expects.
    public let authType: MCPProviderAuthType
    /// SF Symbol used as the chip icon. Vendor logos are intentionally avoided to
    /// keep the binary small and sidestep trademark/asset-licensing concerns.
    public let iconSystemName: String
    /// One-line description shown as a tooltip / accessibility hint.
    public let tagline: String
    /// Where to send the user to obtain a personal API key when the template uses
    /// `authType == .bearerToken`. Rendered as a "Where do I get my key?" link
    /// next to the secure-text field on the connect-known screen.
    public let apiKeyHelpURL: URL?
    /// When non-nil, this template requires the user to deploy and host the MCP
    /// server themselves. Tapping it opens this URL in the browser and routes the
    /// sheet to `.configureCustom` instead of `.configureKnown` so the user can
    /// paste in their own endpoint and credentials once the server is running.
    public let selfHostingHelpURL: URL?
    /// When true (only honoured for `authType == .oauth`), the connect-known
    /// screen renders a "paste Client ID + Client Secret" form instead of the
    /// usual one-tap Sign In button. Used for vendors whose ASM publishes no
    /// `registration_endpoint` (no RFC 7591 DCR) and instead requires the
    /// user to register an OAuth app in a developer portal.
    public let requiresManualOAuthCredentials: Bool
    /// Where to send the user to create the OAuth app for vendors with
    /// `requiresManualOAuthCredentials == true`. Rendered as an "Open … docs"
    /// button next to the Client ID / Secret fields.
    public let oauthSetupHelpURL: URL?
    /// Optional fixed loopback port for the OAuth redirect URI. When non-nil,
    /// `MCPOAuthService.signIn` binds the loopback server to this exact port
    /// and the connect-known screen displays the URL the user must register
    /// in the vendor's portal. Required for vendors that demand exact-match
    /// redirect URIs (HubSpot's MCP Auth Apps).
    public let oauthFixedLoopbackPort: UInt16?

    public init(
        id: String,
        displayName: String,
        url: String,
        authType: MCPProviderAuthType,
        iconSystemName: String,
        tagline: String,
        apiKeyHelpURL: URL? = nil,
        selfHostingHelpURL: URL? = nil,
        requiresManualOAuthCredentials: Bool = false,
        oauthSetupHelpURL: URL? = nil,
        oauthFixedLoopbackPort: UInt16? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.url = url
        self.authType = authType
        self.iconSystemName = iconSystemName
        self.tagline = tagline
        self.apiKeyHelpURL = apiKeyHelpURL
        self.selfHostingHelpURL = selfHostingHelpURL
        self.requiresManualOAuthCredentials = requiresManualOAuthCredentials
        self.oauthSetupHelpURL = oauthSetupHelpURL
        self.oauthFixedLoopbackPort = oauthFixedLoopbackPort
    }

    /// Catalog of well-known providers, alphabetically sorted by `displayName`.
    /// The UI relies on this order being stable across launches.
    public static let allTemplates: [MCPProviderTemplate] = [
        MCPProviderTemplate(
            id: "atlassian",
            displayName: "Atlassian",
            url: "https://mcp.atlassian.com/v1/mcp",
            authType: .bearerToken,
            iconSystemName: "shippingbox.fill",
            tagline: "Search and edit Jira, Confluence, and Compass content",
            apiKeyHelpURL: URL(
                string:
                    "https://support.atlassian.com/atlassian-rovo-mcp-server/docs/configuring-authentication-via-api-token/"
            )!
        ),
        MCPProviderTemplate(
            id: "buildkite",
            displayName: "Buildkite",
            url: "https://mcp.buildkite.com/mcp",
            authType: .oauth,
            iconSystemName: "hammer.fill",
            tagline: "Inspect Buildkite pipelines, builds, and deploys"
        ),
        MCPProviderTemplate(
            id: "canva",
            displayName: "Canva",
            url: "https://mcp.canva.com/mcp",
            authType: .oauth,
            iconSystemName: "paintpalette.fill",
            tagline: "Search and edit your Canva designs"
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
            id: "cloudinary",
            displayName: "Cloudinary",
            url: "https://asset-management.mcp.cloudinary.com/mcp",
            authType: .oauth,
            iconSystemName: "photo.stack.fill",
            tagline: "Browse and transform Cloudinary media assets"
        ),
        MCPProviderTemplate(
            id: "deepwiki",
            displayName: "DeepWiki",
            url: "https://mcp.deepwiki.com/mcp",
            authType: .none,
            iconSystemName: "book.closed.fill",
            tagline: "Q&A over any public GitHub repo"
        ),
        MCPProviderTemplate(
            id: "exa_search",
            displayName: "Exa Search",
            url: "https://mcp.exa.ai/mcp",
            authType: .none,
            iconSystemName: "magnifyingglass",
            tagline: "AI-native web search and content extraction"
        ),
        MCPProviderTemplate(
            id: "github",
            displayName: "GitHub",
            url: "https://api.githubcopilot.com/mcp/",
            authType: .bearerToken,
            iconSystemName: "chevron.left.forwardslash.chevron.right",
            tagline: "Browse repos, issues, and pull requests via Copilot",
            apiKeyHelpURL: URL(
                string:
                    "https://docs.github.com/copilot/how-tos/provide-context/use-mcp-in-your-ide/set-up-the-github-mcp-server"
            )!
        ),
        MCPProviderTemplate(
            id: "google_workspace",
            displayName: "Google Workspace",
            url: "",
            authType: .oauth,
            iconSystemName: "envelope.fill",
            tagline: "Gmail, Calendar, Drive, Docs (requires self-hosting)",
            selfHostingHelpURL: URL(string: "https://github.com/taylorwilsdon/google_workspace_mcp")!
        ),
        // HubSpot's remote MCP server requires confidential-client OAuth via an
        // "MCP Auth App" the user creates in their developer portal. Their ASM
        // does not publish a `registration_endpoint`, so RFC 7591 DCR can never
        // bootstrap a client. Private App PATs (`pat-na1-…`) are explicitly NOT
        // accepted by mcp.hubspot.com — they only work with the REST API and
        // the self-hosted Developer MCP npm package. The fixed loopback port
        // matches the redirect URI the user registers in their MCP Auth App.
        MCPProviderTemplate(
            id: "hubspot",
            displayName: "HubSpot",
            url: "https://mcp.hubspot.com",
            authType: .oauth,
            iconSystemName: "person.crop.rectangle.stack.fill",
            tagline: "Query HubSpot contacts, deals, and pipelines",
            requiresManualOAuthCredentials: true,
            oauthSetupHelpURL: URL(
                string:
                    "https://developers.hubspot.com/docs/apps/developer-platform/build-apps/integrate-with-the-remote-hubspot-mcp-server"
            )!,
            oauthFixedLoopbackPort: 33267
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
            id: "keenable",
            displayName: "Keenable",
            url: "https://api.keenable.ai/mcp",
            authType: .none,
            iconSystemName: "magnifyingglass",
            tagline: "Web search for AI agents"
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
            id: "monday",
            displayName: "monday.com",
            url: "https://mcp.monday.com/mcp",
            authType: .oauth,
            iconSystemName: "square.grid.3x3.fill",
            tagline: "Read and update monday.com boards and items"
        ),
        MCPProviderTemplate(
            id: "neon",
            displayName: "Neon",
            url: "https://mcp.neon.tech/mcp",
            authType: .oauth,
            iconSystemName: "cylinder.fill",
            tagline: "Query and manage Neon Postgres databases"
        ),
        MCPProviderTemplate(
            id: "netlify",
            displayName: "Netlify",
            url: "https://netlify-mcp.netlify.app/mcp",
            authType: .oauth,
            iconSystemName: "network",
            tagline: "Manage Netlify sites, deploys, and DNS"
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
            id: "square",
            displayName: "Square",
            url: "https://mcp.squareup.com/mcp",
            authType: .oauth,
            iconSystemName: "s.square.fill",
            tagline: "Read and manage Square payments and orders"
        ),
        MCPProviderTemplate(
            id: "stackoverflow",
            displayName: "Stack Overflow",
            url: "https://mcp.stackoverflow.com/mcp",
            authType: .oauth,
            iconSystemName: "questionmark.bubble.fill",
            tagline: "Search Stack Overflow for code answers"
        ),
        MCPProviderTemplate(
            id: "stripe",
            displayName: "Stripe",
            url: "https://mcp.stripe.com",
            authType: .oauth,
            iconSystemName: "creditcard.fill",
            tagline: "Read and manage Stripe customers, charges, and subscriptions"
        ),
        MCPProviderTemplate(
            id: "supabase",
            displayName: "Supabase",
            url: "https://mcp.supabase.com/mcp",
            authType: .oauth,
            iconSystemName: "bolt.horizontal.circle.fill",
            tagline: "Manage Supabase Postgres, auth, and storage"
        ),
        MCPProviderTemplate(
            id: "vercel",
            displayName: "Vercel",
            url: "https://mcp.vercel.com/mcp",
            authType: .oauth,
            iconSystemName: "triangle.fill",
            tagline: "Manage Vercel projects, deploys, and DNS"
        ),
        MCPProviderTemplate(
            id: "webflow",
            displayName: "Webflow",
            url: "https://mcp.webflow.com/mcp",
            authType: .oauth,
            iconSystemName: "doc.richtext.fill",
            tagline: "Read and edit Webflow sites and CMS items"
        ),
        MCPProviderTemplate(
            id: "zapier",
            displayName: "Zapier",
            url: "https://mcp.zapier.com/api/mcp/mcp",
            authType: .bearerToken,
            iconSystemName: "bolt.fill",
            tagline: "Trigger 9,000+ apps via Zapier actions",
            apiKeyHelpURL: URL(string: "https://help.zapier.com/hc/en-us/articles/40280119804557")!
        ),
    ]
}
