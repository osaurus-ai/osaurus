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
//  Template kinds:
//
//  1. **One-tap OAuth** (`authType == .oauth`, `requiresManualOAuthCredentials == false`)
//     The default. Tap a card and the connect-known screen runs the full
//     sign-in flow; the client is registered via RFC 7591 dynamic client
//     registration (or a Client ID Metadata Document, see
//     `MCPOAuthClientMetadata`).
//
//  2. **One-tap OAuth via CIMD only** (`requiresClientMetadataDocument == true`)
//     Vendors whose authorization server accepts only Client ID Metadata
//     Documents. Hidden from the directory until Osaurus's metadata document
//     is published, because sign-in cannot succeed before then.
//
//  3. **OAuth without automatic registration** (`requiresManualOAuthCredentials == true`)
//     Vendors whose remote MCP requires an OAuth app registered by hand in the
//     vendor's developer or admin portal (HubSpot, Google, Slack, Zoom, …).
//     The user pastes the resulting client_id + client_secret.
//     `oauthFixedLoopbackPort` pins the loopback redirect URI so the user can
//     register it once with the vendor.
//
//  4. **Bearer-token / API-key** (`authType == .bearerToken`, `apiKeyHelpURL != nil`)
//     Vendors whose remote MCP publishes no OAuth discovery metadata but
//     documents a personal access token / API key (GitHub Copilot MCP).
//
//  5. **No auth** (`authType == .none`) — public data sources.
//
//  Every URL is checked by `scripts/live-proof/probe-mcp-templates.sh`.
//
//  Skipped on purpose (see docs/REMOTE_MCP_PROVIDERS.md for the full list):
//    - Endpoints built for one specific client (`/claude`-only or
//      `/anthropic` paths that reject other clients).
//    - Servers whose OAuth clients only the vendor can issue (Everlaw today),
//      vendors with no hosted MCP server (Clio, Filevine, ADP, Bill.com),
//      per-account URLs that can't be a fixed template (NetSuite), and
//      endpoints the vendor does not document publicly (Lexis+ Protégé).
//    - Developer-only tools beyond the existing set.
//

import Foundation

/// Directory grouping. Declaration order is display order: professional and
/// regulated domains first.
public enum MCPProviderCategory: String, CaseIterable, Sendable {
    case legal
    case financeAccounting
    case investing
    case healthcare
    case documents
    case compliance
    case productivity
    case sales
    case developer

    public var displayName: String {
        switch self {
        case .legal: return "Legal"
        case .financeAccounting: return "Finance & Accounting"
        case .investing: return "Investing & Market Data"
        case .healthcare: return "Healthcare & Life Sciences"
        case .documents: return "Documents & Signatures"
        case .compliance: return "Compliance & Security"
        case .productivity: return "Business Productivity"
        case .sales: return "Sales & CRM"
        case .developer: return "Developer"
        }
    }
}

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
    /// Directory grouping.
    public let category: MCPProviderCategory
    /// SF Symbol used as the chip icon. Vendor logos are intentionally avoided to
    /// keep the binary small and sidestep trademark/asset-licensing concerns.
    public let iconSystemName: String
    /// One-line description shown as a tooltip / accessibility hint.
    public let tagline: String
    /// Enterprise data products that only work with a paid account. Shown as
    /// a note so sign-in walls are not a surprise.
    public let requiresSubscription: Bool
    /// The vendor's authorization server only accepts Client ID Metadata
    /// Documents, so the template is hidden until Osaurus's document is
    /// published.
    public let requiresClientMetadataDocument: Bool
    /// Where to send the user to obtain a personal API key when the template uses
    /// `authType == .bearerToken`. Rendered as a "Where do I get my key?" link
    /// next to the secure-text field on the connect-known screen.
    public let apiKeyHelpURL: URL?
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
    /// redirect URIs.
    public let oauthFixedLoopbackPort: UInt16?

    /// Loopback port shared by every manual-credentials template, so the
    /// redirect URI users register is always `http://127.0.0.1:33267/callback`.
    public static let manualOAuthLoopbackPort: UInt16 = 33267

    /// Idle tool-call timeout a new provider starts with. Legal, market and
    /// clinical research servers routinely run multi-step searches that pass
    /// the generic 45 s budget.
    public var defaultToolCallTimeout: TimeInterval {
        switch category {
        case .legal, .investing, .healthcare: return 120
        default: return 45
        }
    }

    public init(
        id: String,
        displayName: String,
        url: String,
        authType: MCPProviderAuthType,
        category: MCPProviderCategory,
        iconSystemName: String,
        tagline: String,
        requiresSubscription: Bool = false,
        requiresClientMetadataDocument: Bool = false,
        apiKeyHelpURL: URL? = nil,
        requiresManualOAuthCredentials: Bool = false,
        oauthSetupHelpURL: URL? = nil,
        oauthFixedLoopbackPort: UInt16? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.url = url
        self.authType = authType
        self.category = category
        self.iconSystemName = iconSystemName
        self.tagline = tagline
        self.requiresSubscription = requiresSubscription
        self.requiresClientMetadataDocument = requiresClientMetadataDocument
        self.apiKeyHelpURL = apiKeyHelpURL
        self.requiresManualOAuthCredentials = requiresManualOAuthCredentials
        self.oauthSetupHelpURL = oauthSetupHelpURL
        self.oauthFixedLoopbackPort = oauthFixedLoopbackPort
    }

    /// One-tap OAuth template.
    static func oauth(
        _ id: String,
        _ displayName: String,
        _ url: String,
        _ category: MCPProviderCategory,
        icon: String,
        tagline: String,
        subscription: Bool = false,
        metadataDocumentOnly: Bool = false
    ) -> MCPProviderTemplate {
        MCPProviderTemplate(
            id: id,
            displayName: displayName,
            url: url,
            authType: .oauth,
            category: category,
            iconSystemName: icon,
            tagline: tagline,
            requiresSubscription: subscription,
            requiresClientMetadataDocument: metadataDocumentOnly
        )
    }

    /// OAuth template that needs a client registered in the vendor's portal.
    static func manualOAuth(
        _ id: String,
        _ displayName: String,
        _ url: String,
        _ category: MCPProviderCategory,
        icon: String,
        tagline: String,
        setupHelp: String,
        subscription: Bool = false
    ) -> MCPProviderTemplate {
        MCPProviderTemplate(
            id: id,
            displayName: displayName,
            url: url,
            authType: .oauth,
            category: category,
            iconSystemName: icon,
            tagline: tagline,
            requiresSubscription: subscription,
            requiresManualOAuthCredentials: true,
            oauthSetupHelpURL: URL(string: setupHelp)!,
            oauthFixedLoopbackPort: manualOAuthLoopbackPort
        )
    }

    /// Public data source with no sign-in.
    static func open(
        _ id: String,
        _ displayName: String,
        _ url: String,
        _ category: MCPProviderCategory,
        icon: String,
        tagline: String
    ) -> MCPProviderTemplate {
        MCPProviderTemplate(
            id: id,
            displayName: displayName,
            url: url,
            authType: .none,
            category: category,
            iconSystemName: icon,
            tagline: tagline
        )
    }

    /// Templates the directory can offer right now. CIMD-only templates
    /// appear once Osaurus's client metadata document is published.
    public static func available(metadataDocumentPublished: Bool) -> [MCPProviderTemplate] {
        metadataDocumentPublished ? allTemplates : allTemplates.filter { !$0.requiresClientMetadataDocument }
    }

    /// Catalog of well-known providers, sorted by category (declaration
    /// order) and then by `displayName`. The UI relies on this order being
    /// stable across launches.
    public static let allTemplates: [MCPProviderTemplate] = catalog.sorted {
        let lhs = MCPProviderCategory.allCases.firstIndex(of: $0.category)!
        let rhs = MCPProviderCategory.allCases.firstIndex(of: $1.category)!
        if lhs != rhs { return lhs < rhs }
        return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
    }

    private static let catalog: [MCPProviderTemplate] = [
        // MARK: Legal

        .oauth(
            "bloomberg_law", "Bloomberg Law", "https://gw.mcp.bindg.ai/blaw/mcp", .legal,
            icon: "books.vertical.fill", tagline: "Research cases, dockets, and legal news",
            subscription: true
        ),
        .oauth(
            "cocounsel", "CoCounsel Legal", "https://cocoagent-service.cocounsel.thomsonreuters.com/mcp", .legal,
            icon: "text.book.closed.fill", tagline: "Thomson Reuters legal research and drafting",
            subscription: true
        ),
        .oauth(
            "courtlistener", "CourtListener", "https://mcp.courtlistener.com/", .legal,
            icon: "building.columns.fill", tagline: "Search US court opinions, dockets, and judges"
        ),
        .oauth(
            "datasite", "Datasite", "https://mcp.global.datasite.com/mcp", .legal,
            icon: "lock.doc.fill", tagline: "Review M&A data rooms and deal documents",
            subscription: true
        ),
        .oauth(
            "definely", "Definely", "https://mcp.app.definely.com/", .legal,
            icon: "doc.text.magnifyingglass", tagline: "Navigate definitions and clauses in contracts",
            subscription: true
        ),
        .oauth(
            "descrybe", "Descrybe", "https://mcp.descrybe.com/mcp", .legal,
            icon: "scalemass.fill", tagline: "Search US case law summaries"
        ),
        .manualOAuth(
            "harvey", "Harvey", "https://api.harvey.ai/hosted_mcp/mcp", .legal,
            icon: "brain.head.profile", tagline: "Legal Q&A, Vault documents, and research sources",
            setupHelp: "https://developers.harvey.ai/guides/harvey_mcp", subscription: true
        ),
        .oauth(
            "imanage", "iManage Work", "https://cloudimanage.com/mcp/work", .legal,
            icon: "archivebox.fill", tagline: "Find and read documents in iManage Work",
            subscription: true
        ),
        .oauth(
            "ironclad", "Ironclad", "https://mcp.na1.ironcladapp.com/mcp", .legal,
            icon: "doc.badge.gearshape", tagline: "Search contracts and workflows in Ironclad",
            subscription: true, metadataDocumentOnly: true
        ),
        .oauth(
            "juro", "Juro", "https://integrations.app.juro.com/mcp", .legal,
            icon: "signature", tagline: "Draft, review, and track contracts in Juro",
            subscription: true
        ),
        .oauth(
            "lawvu", "LawVu", "https://mcp.lawvu.com/mcp", .legal,
            icon: "briefcase.fill", tagline: "Manage in-house legal matters and contracts",
            subscription: true
        ),
        .oauth(
            "legal_data_hunter", "Legal Data Hunter", "https://legaldatahunter.com/mcp", .legal,
            icon: "globe", tagline: "Search legislation and case law across countries"
        ),
        .oauth(
            "legalzoom", "LegalZoom", "https://www.legalzoom.com/mcp/claude/v1", .legal,
            icon: "building.2.fill", tagline: "Business formation and legal document guidance"
        ),
        .oauth(
            "midpage", "Midpage", "https://app.midpage.ai/mcp", .legal,
            icon: "magnifyingglass.circle.fill", tagline: "Legal research with cited case law",
            subscription: true
        ),
        .oauth(
            "mycase", "MyCase", "https://mcp.mycase.com/mcp", .legal,
            icon: "person.2.fill", tagline: "Cases, clients, and calendars in MyCase",
            subscription: true, metadataDocumentOnly: true
        ),
        .oauth(
            "netdocuments", "NetDocuments", "https://web-api.us.netdocuments.app/connect/mcp", .legal,
            icon: "doc.on.doc.fill", tagline: "Find and read documents in NetDocuments",
            subscription: true
        ),

        // MARK: Finance & Accounting

        .oauth(
            "brex", "Brex", "https://api.brex.com/mcp", .financeAccounting,
            icon: "creditcard.and.123", tagline: "Review Brex card spend, expenses, and budgets",
            subscription: true
        ),
        .oauth(
            "carta", "Carta", "https://mcp.app.carta.com/mcp", .financeAccounting,
            icon: "person.3.sequence.fill", tagline: "Cap tables, equity, and fund data in Carta",
            subscription: true
        ),
        .oauth(
            "datarails", "Datarails", "https://mcp.datarails.com/mcp", .financeAccounting,
            icon: "chart.bar.xaxis", tagline: "FP&A reporting and budgets in Datarails",
            subscription: true
        ),
        .oauth(
            "deel", "Deel", "https://api.letsdeel.com/mcp", .financeAccounting,
            icon: "globe.americas.fill", tagline: "Payroll, contracts, and people data in Deel",
            subscription: true
        ),
        .oauth(
            "digits", "Digits", "https://api.digits.com/mcp", .financeAccounting,
            icon: "number.circle.fill", tagline: "Books, financial statements, and cash in Digits",
            subscription: true
        ),
        .oauth(
            "dualentry", "DualEntry", "https://api.dualentry.com/mcp", .financeAccounting,
            icon: "list.bullet.rectangle.fill", tagline: "General ledger and accounting in DualEntry",
            subscription: true
        ),
        .oauth(
            "freshbooks", "FreshBooks", "https://mcp.freshbooks.com/v1", .financeAccounting,
            icon: "doc.plaintext.fill", tagline: "Invoices, expenses, and clients in FreshBooks"
        ),
        .oauth(
            "gocardless", "GoCardless", "https://mcp.gocardless.com/", .financeAccounting,
            icon: "arrow.triangle.2.circlepath.circle.fill", tagline: "Direct debit payments and mandates"
        ),
        .oauth(
            "gusto", "Gusto", "https://mcp.api.gusto.com", .financeAccounting,
            icon: "person.text.rectangle.fill", tagline: "Payroll, employees, and tax data in Gusto (read-only)"
        ),
        .oauth(
            "mercury", "Mercury", "https://mcp.mercury.com/mcp", .financeAccounting,
            icon: "banknote.fill", tagline: "Business bank accounts and transactions"
        ),
        .oauth(
            "myob", "MYOB", "https://mcp.myob.com/mcp", .financeAccounting,
            icon: "chart.pie.fill", tagline: "Accounting and payroll data in MYOB"
        ),
        .oauth(
            "paypal", "PayPal", "https://mcp.paypal.com/mcp", .financeAccounting,
            icon: "p.circle.fill", tagline: "Query and manage PayPal payments and orders"
        ),
        .oauth(
            "pocketsmith", "PocketSmith", "https://mcp.pocketsmith.com/mcp", .financeAccounting,
            icon: "calendar.badge.clock", tagline: "Personal budgets and cash-flow forecasts"
        ),
        .oauth(
            "qonto", "Qonto", "https://mcp.qonto.com/mcp", .financeAccounting,
            icon: "eurosign.circle.fill", tagline: "Business banking and transactions in Qonto"
        ),
        .oauth(
            "quickbooks", "QuickBooks", "https://mcp.quickbooks.intuit.com/mcp", .financeAccounting,
            icon: "q.circle.fill", tagline: "Invoices, customers, and reports in QuickBooks Online"
        ),
        .oauth(
            "ramp", "Ramp", "https://ramp-mcp-remote.ramp.com/mcp", .financeAccounting,
            icon: "arrow.up.right.circle.fill", tagline: "Corporate cards, bills, and spend in Ramp",
            subscription: true
        ),
        .oauth(
            "rillet", "Rillet", "https://api.rillet.com/mcp", .financeAccounting,
            icon: "tablecells.fill", tagline: "ERP ledger, revenue, and close in Rillet",
            subscription: true
        ),
        .oauth(
            "square", "Square", "https://mcp.squareup.com/mcp", .financeAccounting,
            icon: "s.square.fill", tagline: "Read and manage Square payments and orders"
        ),
        .oauth(
            "stripe", "Stripe", "https://mcp.stripe.com", .financeAccounting,
            icon: "creditcard.fill", tagline: "Read and manage Stripe customers, charges, and subscriptions"
        ),
        .open(
            "taxact", "TaxAct", "https://mcp.taxact.com/mcp", .financeAccounting,
            icon: "percent", tagline: "US tax questions and filing guidance"
        ),
        .oauth(
            "tiller", "Tiller", "https://ai-tools.tillermoney.com/mcp", .financeAccounting,
            icon: "tablecells.badge.ellipsis", tagline: "Spending and budget spreadsheets from Tiller"
        ),
        .manualOAuth(
            "xero", "Xero", "https://mcp.xero.com/mcp", .financeAccounting,
            icon: "x.circle.fill", tagline: "Financial reports, invoices, and contacts in Xero",
            setupHelp: "https://developer.xero.com/app/manage"
        ),
        .oauth(
            "zoho_books", "Zoho Books", "https://claude-zohobooks.zohomcp.com/mcp/message", .financeAccounting,
            icon: "book.fill", tagline: "Invoices, bills, and accounting in Zoho Books"
        ),

        // MARK: Investing & Market Data

        .oauth(
            "addepar", "Addepar", "https://mcp.addepar.com/", .investing,
            icon: "chart.pie", tagline: "Portfolio and wealth data in Addepar",
            subscription: true
        ),
        .oauth(
            "affinity", "Affinity", "https://mcp.affinity.co/mcp", .investing,
            icon: "point.3.connected.trianglepath.dotted", tagline: "Relationship intelligence for deal teams",
            subscription: true, metadataDocumentOnly: true
        ),
        .oauth(
            "alpha_vantage", "Alpha Vantage", "https://mcp.alphavantage.co/mcp", .investing,
            icon: "waveform.path.ecg", tagline: "Stock, forex, and economic market data"
        ),
        .oauth(
            "crunchbase", "Crunchbase", "https://mcp.crunchbase.com/", .investing,
            icon: "building.2.crop.circle", tagline: "Company, funding, and investor data",
            metadataDocumentOnly: true
        ),
        .oauth(
            "daloopa", "Daloopa", "https://mcp.daloopa.com/server/mcp", .investing,
            icon: "tablecells", tagline: "Fundamental data from company filings",
            subscription: true
        ),
        .oauth(
            "factset", "FactSet", "https://mcp.factset.com/content/v1", .investing,
            icon: "chart.xyaxis.line", tagline: "Financial data and analytics from FactSet",
            subscription: true
        ),
        .oauth(
            "fmp", "Financial Modeling Prep", "https://financialmodelingprep.com/mcp", .investing,
            icon: "dollarsign.circle.fill", tagline: "Financial statements, prices, and ratios",
            metadataDocumentOnly: true
        ),
        .oauth(
            "lseg", "LSEG", "https://api.analytics.lseg.com/lfa/mcp/server-cl", .investing,
            icon: "globe.europe.africa.fill", tagline: "LSEG financial analytics and market data",
            subscription: true
        ),
        .oauth(
            "moodys", "Moody's", "https://mcp.moodys.com/genai-ready-data/Credit/mcp", .investing,
            icon: "checkmark.seal.fill", tagline: "Credit ratings and research from Moody's",
            subscription: true
        ),
        .oauth(
            "morningstar", "Morningstar", "https://mcp.morningstar.com/mcp", .investing,
            icon: "star.circle.fill", tagline: "Fund, stock, and portfolio research",
            subscription: true
        ),
        .oauth(
            "pitchbook", "PitchBook", "https://premium.mcp.pitchbook.com/mcp", .investing,
            icon: "chart.line.uptrend.xyaxis", tagline: "Private market companies, deals, and investors",
            subscription: true
        ),
        .oauth(
            "sp_global", "S&P Global", "https://kfinance.kensho.com/integrations/mcp", .investing,
            icon: "chart.bar.fill", tagline: "S&P Capital IQ financials via Kensho",
            subscription: true
        ),
        .oauth(
            "wealthbox", "Wealthbox", "https://mcp.crmworkspace.com/mcp", .investing,
            icon: "person.crop.circle.badge.checkmark", tagline: "CRM for financial advisors",
            subscription: true, metadataDocumentOnly: true
        ),

        // MARK: Healthcare & Life Sciences

        .oauth(
            "consensus", "Consensus", "https://mcp.consensus.app/mcp", .healthcare,
            icon: "text.magnifyingglass", tagline: "Answers from peer-reviewed research papers"
        ),
        .oauth(
            "cortellis", "Cortellis Regulatory", "https://api.clarivate.com/lifesciences/mcp-regulatory/mcp",
            .healthcare,
            icon: "pills.fill", tagline: "Drug regulatory intelligence from Clarivate",
            subscription: true
        ),
        .oauth(
            "elicit", "Elicit", "https://elicit.com/api/mcp", .healthcare,
            icon: "lightbulb.fill", tagline: "Search and summarize scientific literature"
        ),
        .oauth(
            "healthex", "HealthEx", "https://api.healthex.io/mcp", .healthcare,
            icon: "heart.text.square.fill", tagline: "Your own health records, with your consent"
        ),
        .oauth(
            "medidata", "Medidata", "https://mcp.imedidata.com/mcp", .healthcare,
            icon: "cross.case.fill", tagline: "Clinical trial data in Medidata",
            subscription: true
        ),
        .open(
            "open_targets", "Open Targets", "https://mcp.platform.opentargets.org/mcp", .healthcare,
            icon: "scope", tagline: "Drug target and disease association data"
        ),
        .oauth(
            "scite", "Scite", "https://api.scite.ai/mcp", .healthcare,
            icon: "quote.bubble.fill", tagline: "See how research papers are cited"
        ),
        .open(
            "snomed_ct", "SNOMED CT", "https://snowstorm-mcp.snomedtools.org/mcp", .healthcare,
            icon: "stethoscope", tagline: "Look up clinical terminology codes"
        ),
        .oauth(
            "turquoise_health", "Turquoise Health", "https://mcp.turquoise.health/mcp", .healthcare,
            icon: "dollarsign.square.fill", tagline: "Healthcare price transparency data"
        ),
        .oauth(
            "wiley", "Wiley Scholar Gateway", "https://connector.scholargateway.ai/v2/mcp", .healthcare,
            icon: "graduationcap.fill", tagline: "Search peer-reviewed Wiley research"
        ),

        // MARK: Documents & Signatures

        .manualOAuth(
            "box", "Box", "https://mcp.box.com/", .documents,
            icon: "shippingbox.fill", tagline: "Search and read files in Box",
            setupHelp: "https://developer.box.com/guides/box-mcp/setup", subscription: true
        ),
        .manualOAuth(
            "docusign", "Docusign", "https://mcp.docusign.com/mcp", .documents,
            icon: "signature", tagline: "Envelopes, agreements, and signing status",
            setupHelp: "https://developers.docusign.com/platform/mcp-server/"
        ),
        .oauth(
            "dropbox", "Dropbox", "https://mcp.dropbox.com/mcp", .documents,
            icon: "archivebox", tagline: "Browse, search, and manage files in Dropbox"
        ),
        .oauth(
            "egnyte", "Egnyte", "https://mcp-server.egnyte.com/mcp", .documents,
            icon: "externaldrive.fill", tagline: "Search and read files in Egnyte",
            subscription: true
        ),
        .oauth(
            "pandadoc", "PandaDoc", "https://mcp.pandadoc.com/v1/mcp", .documents,
            icon: "doc.richtext", tagline: "Proposals, quotes, and e-signatures"
        ),
        .oauth(
            "signnow", "SignNow", "https://mcp-server.signnow.com/mcp", .documents,
            icon: "pencil.and.outline", tagline: "Send documents for e-signature"
        ),

        // MARK: Compliance & Security

        .oauth(
            "iubenda", "iubenda", "https://mcp-server.iubenda.com/mcp", .compliance,
            icon: "hand.raised.fill", tagline: "Privacy policies, cookie consent, and GDPR records"
        ),
        .oauth(
            "vanta", "Vanta", "https://mcp.vanta.com/mcp", .compliance,
            icon: "checkmark.shield.fill", tagline: "SOC 2, ISO 27001, and HIPAA compliance status",
            subscription: true
        ),

        // MARK: Business Productivity

        .oauth(
            "airtable", "Airtable", "https://mcp.airtable.com/mcp", .productivity,
            icon: "square.grid.3x2.fill", tagline: "Read and update Airtable bases and records"
        ),
        .manualOAuth(
            "asana", "Asana", "https://mcp.asana.com/v2/mcp", .productivity,
            icon: "checkmark.circle.fill", tagline: "Tasks, projects, and goals in Asana",
            setupHelp: "https://developers.asana.com/docs/integrating-with-asanas-mcp-server"
        ),
        .oauth(
            "atlassian", "Atlassian", "https://mcp.atlassian.com/v2/mcp", .productivity,
            icon: "square.stack.3d.up.fill", tagline: "Search and edit Jira and Confluence content"
        ),
        .oauth(
            "calendly", "Calendly", "https://mcp.calendly.com/", .productivity,
            icon: "calendar.badge.plus", tagline: "Scheduling links and booked meetings"
        ),
        .oauth(
            "canva", "Canva", "https://mcp.canva.com/mcp", .productivity,
            icon: "paintpalette.fill", tagline: "Search and edit your Canva designs"
        ),
        .oauth(
            "clickup", "ClickUp", "https://mcp.clickup.com/mcp", .productivity,
            icon: "checklist", tagline: "Tasks, docs, and goals in ClickUp"
        ),
        .oauth(
            "deepl", "DeepL", "https://mcp.deepl.com/v1/mcp", .productivity,
            icon: "character.bubble.fill", tagline: "Translate text and documents"
        ),
        .oauth(
            "dropbox_dash", "Dropbox Dash", "https://mcp.dropbox.com/dash", .productivity,
            icon: "text.magnifyingglass", tagline: "Search across the work apps connected to Dash",
            subscription: true
        ),
        .open(
            "excalidraw", "Excalidraw", "https://mcp.excalidraw.com/mcp", .productivity,
            icon: "scribble.variable", tagline: "Sketch diagrams and whiteboards"
        ),
        .open(
            "exa_search", "Exa Search", "https://mcp.exa.ai/mcp", .productivity,
            icon: "magnifyingglass", tagline: "AI-native web search and content extraction"
        ),
        .oauth(
            "fireflies", "Fireflies", "https://api.fireflies.ai/mcp", .productivity,
            icon: "waveform", tagline: "Meeting transcripts and summaries"
        ),
        .oauth(
            "gamma", "Gamma", "https://mcp.gamma.app/mcp", .productivity,
            icon: "rectangle.on.rectangle", tagline: "Generate presentations and documents"
        ),
        .manualOAuth(
            "gmail", "Gmail", "https://gmailmcp.googleapis.com/mcp/v1", .productivity,
            icon: "envelope.fill", tagline: "Search and draft email in Gmail",
            setupHelp: "https://developers.google.com/workspace/guides/configure-mcp-servers"
        ),
        .manualOAuth(
            "google_calendar", "Google Calendar", "https://calendarmcp.googleapis.com/mcp/v1", .productivity,
            icon: "calendar", tagline: "Events and availability in Google Calendar",
            setupHelp: "https://developers.google.com/workspace/guides/configure-mcp-servers"
        ),
        .manualOAuth(
            "google_drive", "Google Drive", "https://drivemcp.googleapis.com/mcp/v1", .productivity,
            icon: "folder.fill", tagline: "Search and read files in Google Drive",
            setupHelp: "https://developers.google.com/workspace/drive/api/guides/configure-mcp-server"
        ),
        .oauth(
            "granola", "Granola", "https://mcp.granola.ai/mcp", .productivity,
            icon: "note.text", tagline: "Meeting notes from Granola"
        ),
        .open(
            "keenable", "Keenable", "https://api.keenable.ai/mcp", .productivity,
            icon: "magnifyingglass.circle", tagline: "Web search for AI agents"
        ),
        .manualOAuth(
            "microsoft_365", "Microsoft 365", "https://workiq.svc.cloud.microsoft/mcp", .productivity,
            icon: "square.grid.2x2.fill", tagline: "Outlook mail and calendar, Teams, OneDrive, and SharePoint",
            setupHelp: "https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/work-iq/mcp/overview",
            subscription: true
        ),
        .oauth(
            "miro", "Miro", "https://mcp.miro.com/", .productivity,
            icon: "rectangle.on.rectangle.angled", tagline: "Read and create Miro boards"
        ),
        .oauth(
            "monday", "monday.com", "https://mcp.monday.com/mcp", .productivity,
            icon: "square.grid.3x3.fill", tagline: "Read and update monday.com boards and items"
        ),
        .oauth(
            "notion", "Notion", "https://mcp.notion.com/mcp", .productivity,
            icon: "doc.text.fill", tagline: "Read and edit your Notion pages and databases"
        ),
        .manualOAuth(
            "slack", "Slack", "https://mcp.slack.com/mcp", .productivity,
            icon: "number.square.fill", tagline: "Search and send messages in Slack",
            setupHelp: "https://docs.slack.dev/ai/slack-mcp-server/"
        ),
        .oauth(
            "todoist", "Todoist", "https://ai.todoist.net/mcp", .productivity,
            icon: "checkmark.square.fill", tagline: "Tasks and projects in Todoist"
        ),
        .oauth(
            "trello", "Trello", "https://mcp.trello.com/v1", .productivity,
            icon: "rectangle.split.3x1.fill", tagline: "Boards, lists, and cards in Trello"
        ),
        .oauth(
            "webflow", "Webflow", "https://mcp.webflow.com/mcp", .productivity,
            icon: "doc.richtext.fill", tagline: "Read and edit Webflow sites and CMS items"
        ),
        .oauth(
            "zapier", "Zapier", "https://mcp.zapier.com/api/mcp/mcp", .productivity,
            icon: "bolt.fill", tagline: "Trigger 9,000+ apps via Zapier actions"
        ),
        .manualOAuth(
            "zoom", "Zoom", "https://mcp.zoom.us/mcp/zoom/streamable", .productivity,
            icon: "video.fill", tagline: "Meetings, recordings, and AI summaries in Zoom",
            setupHelp: "https://developers.zoom.us/docs/mcp/servers/connect-to-zoom-mcp-servers/"
        ),

        // MARK: Sales & CRM

        .oauth(
            "attio", "Attio", "https://mcp.attio.com/mcp", .sales,
            icon: "person.text.rectangle.fill", tagline: "Contacts, companies, and deals in Attio"
        ),
        .oauth(
            "close", "Close", "https://mcp.close.com/mcp", .sales,
            icon: "phone.fill", tagline: "Leads, calls, and pipeline in Close"
        ),
        // HubSpot's remote MCP server requires confidential-client OAuth via an
        // "MCP Auth App" the user creates in their developer portal. Private App
        // PATs (`pat-na1-…`) are explicitly NOT accepted by mcp.hubspot.com —
        // they only work with the REST API and the self-hosted Developer MCP
        // npm package.
        .manualOAuth(
            "hubspot", "HubSpot", "https://mcp.hubspot.com", .sales,
            icon: "person.crop.rectangle.stack.fill", tagline: "Query HubSpot contacts, deals, and pipelines",
            setupHelp:
                "https://developers.hubspot.com/docs/apps/developer-platform/build-apps/integrate-with-the-remote-hubspot-mcp-server"
        ),
        .oauth(
            "intercom", "Intercom", "https://mcp.intercom.com/mcp", .sales,
            icon: "bubble.left.and.bubble.right.fill", tagline: "Customer conversations and contacts"
        ),
        .oauth(
            "salesforce", "Salesforce", "https://api.salesforce.com/platform/mcp/v1/platform/headless-360", .sales,
            icon: "person.2.crop.square.stack.fill", tagline: "Accounts, opportunities, and records in Salesforce",
            subscription: true
        ),

        // MARK: Developer

        .oauth(
            "buildkite", "Buildkite", "https://mcp.buildkite.com/mcp", .developer,
            icon: "hammer.fill", tagline: "Inspect Buildkite pipelines, builds, and deploys"
        ),
        .oauth(
            "cloudflare", "Cloudflare", "https://mcp.cloudflare.com/mcp", .developer,
            icon: "cloud.fill", tagline: "Manage your Cloudflare account, workers, and DNS"
        ),
        .oauth(
            "cloudinary", "Cloudinary", "https://asset-management.mcp.cloudinary.com/mcp", .developer,
            icon: "photo.stack.fill", tagline: "Browse and transform Cloudinary media assets"
        ),
        .open(
            "deepwiki", "DeepWiki", "https://mcp.deepwiki.com/mcp", .developer,
            icon: "book.closed.fill", tagline: "Q&A over any public GitHub repo"
        ),
        MCPProviderTemplate(
            id: "github",
            displayName: "GitHub",
            url: "https://api.githubcopilot.com/mcp/",
            authType: .bearerToken,
            category: .developer,
            iconSystemName: "chevron.left.forwardslash.chevron.right",
            tagline: "Browse repos, issues, and pull requests via Copilot",
            apiKeyHelpURL: URL(
                string:
                    "https://docs.github.com/copilot/how-tos/provide-context/use-mcp-in-your-ide/set-up-the-github-mcp-server"
            )!
        ),
        .oauth(
            "huggingface", "Hugging Face", "https://huggingface.co/mcp", .developer,
            icon: "face.smiling.fill", tagline: "Search models, datasets, papers, and Spaces"
        ),
        .oauth(
            "linear", "Linear", "https://mcp.linear.app/mcp", .developer,
            icon: "chart.bar.doc.horizontal.fill", tagline: "Read and update Linear issues, projects, and cycles"
        ),
        .oauth(
            "neon", "Neon", "https://mcp.neon.tech/mcp", .developer,
            icon: "cylinder.fill", tagline: "Query and manage Neon Postgres databases"
        ),
        .oauth(
            "netlify", "Netlify", "https://netlify-mcp.netlify.app/mcp", .developer,
            icon: "network", tagline: "Manage Netlify sites, deploys, and DNS"
        ),
        .oauth(
            "sentry", "Sentry", "https://mcp.sentry.dev/mcp", .developer,
            icon: "exclamationmark.shield.fill", tagline: "Investigate Sentry issues, traces, and releases"
        ),
        .oauth(
            "supabase", "Supabase", "https://mcp.supabase.com/mcp", .developer,
            icon: "bolt.horizontal.circle.fill", tagline: "Manage Supabase Postgres, auth, and storage"
        ),
        .oauth(
            "vercel", "Vercel", "https://mcp.vercel.com/", .developer,
            icon: "triangle.fill", tagline: "Manage Vercel projects, deploys, and DNS"
        ),
    ]
}
