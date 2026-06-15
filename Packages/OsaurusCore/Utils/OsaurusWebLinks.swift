//
//  OsaurusWebLinks.swift
//  osaurus
//
//  Canonical osaurus.ai web links and the legal/disclosure copy that embeds
//  them. Single source of truth so the same URLs and wording are reused across
//  every in-product surface (onboarding, Settings, the credit top-up sheet) and
//  never drift. The pages themselves are hosted on the osaurus.ai website, not
//  in this app.
//

import Foundation

public enum OsaurusWebLinks {
    /// Terms of Service. Linked from first-run acceptance, the credit top-up
    /// sheet, and the Settings → Legal section.
    public static let terms = URL(string: "https://osaurus.ai/terms")!

    /// Privacy Policy. Also the destination for the diagnostics disclosures
    /// (anonymous usage data and crash reports); by product decision these link
    /// to the page root rather than a section anchor.
    public static let privacy = URL(string: "https://osaurus.ai/privacy")!

    // MARK: - Localized link copy

    /// "By continuing, you agree to the Terms and Privacy Policy." with both
    /// documents linked. Shared by first-run acceptance and the credit top-up
    /// sheet so the affirmative-acceptance wording stays identical. Rendered
    /// with `MarkdownLinkText`.
    static var acceptanceMarkdown: String {
        String(
            format: L("By continuing, you agree to the [Terms](%1$@) and [Privacy Policy](%2$@)."),
            terms.absoluteString,
            privacy.absoluteString
        )
    }

    /// Diagnostics disclosure for the anonymous-usage opt-in (welcome info
    /// popover), linking to the Privacy Policy.
    static var usageDiagnosticsMarkdown: String {
        String(
            format: L("Learn more in our [Privacy Policy](%1$@)."),
            privacy.absoluteString
        )
    }

    /// Diagnostics disclosure for the crash-report consent (final onboarding
    /// step), linking to the Privacy Policy.
    static var crashDiagnosticsMarkdown: String {
        String(
            format: L("Learn how in our [Privacy Policy](%1$@)."),
            privacy.absoluteString
        )
    }
}
