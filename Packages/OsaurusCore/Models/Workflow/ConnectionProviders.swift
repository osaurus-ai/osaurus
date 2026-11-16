//
//  ConnectionProviders.swift
//  osaurus
//
//  Services people commonly connect a workflow to, with what a
//  `declare_connection` needs to know about each: the host the login is
//  for, the API hosts its steps reach, the OAuth 2.0 endpoints when the
//  service offers a sign-in, and where a personal token comes from when
//  it offers that instead (or as well). The Architect names a provider
//  and gets a complete secret declaration; nothing here holds a value.
//

import Foundation

public struct ConnectionProvider: Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// The host the credential logs into; connections match on it.
    public let service: String
    /// Hosts an `http` step typically reaches with this login.
    public let apiHosts: [String]
    /// The sign-in, when the service offers OAuth 2.0 for personal use.
    public let oauth2: OAuth2Spec?
    /// Where a personal token or API key comes from; nil when the service
    /// issues none and only a sign-in works.
    public let tokenHelp: String?
    /// Where to register an OAuth app when the vendor issues no public
    /// client ids, including the redirect URL to add.
    public let oauthHelp: String?
    /// The page where that OAuth app is created.
    public let appSetupURL: String?
    /// The authorize request fails without at least one scope (Google).
    public var requiresScopes: Bool = false

    public var supportsSignIn: Bool { oauth2 != nil }
    public var supportsToken: Bool { tokenHelp != nil }
}

public enum ConnectionProviders {
    public static func provider(id: String) -> ConnectionProvider? {
        let key = id.trimmingCharacters(in: .whitespaces).lowercased()
        return all.first { $0.id == key }
    }

    /// `id: name` pairs for tool descriptions, in catalog order.
    public static var summary: String {
        all.map { "\($0.id) (\($0.supportsSignIn ? "sign-in" : "")\($0.supportsSignIn && $0.supportsToken ? " or " : "")\($0.supportsToken ? "token" : ""))" }
            .joined(separator: ", ")
    }

    private static let redirect = OAuth2ConnectionFlow.redirectURL

    public static let all: [ConnectionProvider] = [
        ConnectionProvider(
            id: "github", name: "GitHub", service: "api.github.com", apiHosts: ["api.github.com"],
            oauth2: OAuth2Spec(
                authorizeURL: "https://github.com/login/oauth/authorize",
                tokenURL: "https://github.com/login/oauth/access_token", scopes: ["repo", "read:user"],
                requiresClientSecret: true),
            tokenHelp: "GitHub → Settings → Developer settings → Personal access tokens. Give it the repo scope.",
            oauthHelp:
                "GitHub → Settings → Developer settings → OAuth Apps → New OAuth App. Set Authorization callback URL to \(redirect), then paste its Client ID and a new Client Secret.",
            appSetupURL: "https://github.com/settings/developers"),
        ConnectionProvider(
            id: "gitlab", name: "GitLab", service: "gitlab.com", apiHosts: ["gitlab.com"],
            oauth2: OAuth2Spec(
                authorizeURL: "https://gitlab.com/oauth/authorize", tokenURL: "https://gitlab.com/oauth/token",
                scopes: ["read_api"]),
            tokenHelp: "GitLab → Preferences → Access tokens. Give it the read_api scope (api to write).",
            oauthHelp:
                "GitLab → Preferences → Applications → Add new application. Set Redirect URI to \(redirect), untick Confidential, then paste the Application ID.",
            appSetupURL: "https://gitlab.com/-/user_settings/applications"),
        ConnectionProvider(
            id: "google", name: "Google", service: "www.googleapis.com",
            apiHosts: ["www.googleapis.com", "gmail.googleapis.com", "sheets.googleapis.com", "drive.googleapis.com"],
            oauth2: OAuth2Spec(
                authorizeURL: "https://accounts.google.com/o/oauth2/v2/auth",
                tokenURL: "https://oauth2.googleapis.com/token", scopes: [], requiresClientSecret: true,
                authorizeParameters: ["access_type": "offline", "prompt": "consent"]),
            tokenHelp: nil,
            oauthHelp:
                "Google Cloud Console → APIs & Services → Credentials → Create OAuth client, type Desktop app (it needs no redirect URL). Paste its Client ID and Client Secret.",
            appSetupURL: "https://console.cloud.google.com/apis/credentials",
            requiresScopes: true),
        ConnectionProvider(
            id: "microsoft", name: "Microsoft", service: "graph.microsoft.com", apiHosts: ["graph.microsoft.com"],
            oauth2: OAuth2Spec(
                authorizeURL: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
                tokenURL: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
                scopes: ["offline_access", "User.Read"]),
            tokenHelp: nil,
            oauthHelp:
                "Microsoft Entra admin center → App registrations → New registration. Under Authentication, add the Mobile and desktop applications platform with the custom redirect URI \(redirect), then paste the Application (client) ID.",
            appSetupURL: "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade"),
        ConnectionProvider(
            id: "slack", name: "Slack", service: "slack.com", apiHosts: ["slack.com"],
            oauth2: OAuth2Spec(
                authorizeURL: "https://slack.com/oauth/v2/authorize", tokenURL: "https://slack.com/api/oauth.v2.access",
                scopes: ["channels:read", "chat:write"], requiresClientSecret: true, scopeSeparator: ","),
            tokenHelp: "api.slack.com → Your Apps → OAuth & Permissions → Bot User OAuth Token (xoxb-…) after installing the app to the workspace.",
            oauthHelp:
                "api.slack.com/apps → Create New App → OAuth & Permissions → Redirect URLs → add \(redirect) and Save URLs (if the form refuses an http URL, add it under App Manifest → oauth_config.redirect_urls). Then paste the Client ID and Client Secret from Basic Information.",
            appSetupURL: "https://api.slack.com/apps"),
        ConnectionProvider(
            id: "linear", name: "Linear", service: "api.linear.app", apiHosts: ["api.linear.app"],
            oauth2: OAuth2Spec(
                authorizeURL: "https://linear.app/oauth/authorize", tokenURL: "https://api.linear.app/oauth/token",
                scopes: ["read"], requiresClientSecret: true, scopeSeparator: ","),
            tokenHelp: "Linear → Settings → Security & access → Personal API keys.",
            oauthHelp:
                "Linear → Settings → API → OAuth applications → New. Add \(redirect) to Callback URLs, then paste its Client ID and Client Secret.",
            appSetupURL: "https://linear.app/settings/api"),
        ConnectionProvider(
            id: "notion", name: "Notion", service: "api.notion.com", apiHosts: ["api.notion.com"],
            oauth2: OAuth2Spec(
                authorizeURL: "https://api.notion.com/v1/oauth/authorize",
                tokenURL: "https://api.notion.com/v1/oauth/token", scopes: [], requiresClientSecret: true,
                authorizeParameters: ["owner": "user"], clientSecretBasic: true, jsonTokenBody: true),
            tokenHelp: "notion.so/profile/integrations → New integration → Internal Integration Secret; then share each page with the integration.",
            oauthHelp:
                "notion.so/profile/integrations → New integration, type Public. Add \(redirect) under Redirect URIs, then paste its OAuth Client ID and Client Secret.",
            appSetupURL: "https://www.notion.so/profile/integrations"),
        ConnectionProvider(
            id: "dropbox", name: "Dropbox", service: "api.dropboxapi.com",
            apiHosts: ["api.dropboxapi.com", "content.dropboxapi.com"],
            oauth2: OAuth2Spec(
                authorizeURL: "https://www.dropbox.com/oauth2/authorize",
                tokenURL: "https://api.dropboxapi.com/oauth2/token", scopes: [],
                authorizeParameters: ["token_access_type": "offline"]),
            tokenHelp: nil,
            oauthHelp:
                "dropbox.com/developers/apps → Create app. Under Settings → OAuth 2 → Redirect URIs, add \(redirect), then paste its App key as the client id.",
            appSetupURL: "https://www.dropbox.com/developers/apps"),
        ConnectionProvider(
            id: "spotify", name: "Spotify", service: "api.spotify.com", apiHosts: ["api.spotify.com"],
            oauth2: OAuth2Spec(
                authorizeURL: "https://accounts.spotify.com/authorize", tokenURL: "https://accounts.spotify.com/api/token",
                scopes: ["user-read-private"]),
            tokenHelp: nil,
            oauthHelp: "developer.spotify.com/dashboard → Create app with the Redirect URI \(redirect), then paste its Client ID.",
            appSetupURL: "https://developer.spotify.com/dashboard"),
        ConnectionProvider(
            id: "stripe", name: "Stripe", service: "api.stripe.com", apiHosts: ["api.stripe.com"], oauth2: nil,
            tokenHelp: "Stripe Dashboard → Developers → API keys. Use a restricted key with only the permissions the steps need.",
            oauthHelp: nil, appSetupURL: nil),
    ]
}
