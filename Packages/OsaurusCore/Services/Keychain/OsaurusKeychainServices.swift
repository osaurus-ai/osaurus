//
//  OsaurusKeychainServices.swift
//  osaurus
//
//  Central registry of every Keychain service Osaurus writes to.
//

import Foundation

/// Every generic-password service name the app stores secrets under.
///
/// Factory reset (`OnboardingService`) wipes exactly this list; keeping it
/// next to the wrappers (instead of a hard-coded copy in the reset flow)
/// means a new secret store added with its own service string is one line
/// away from being covered by reset. If you add a keychain-backed store,
/// register its service here.
public enum OsaurusKeychainServices {
    /// Master identity seed + recovery mnemonic (`MasterKey`,
    /// `MasterMnemonicStore`).
    public static let account = "com.osaurus.account"
    /// SQLCipher storage key (`StorageKeyManager`).
    public static let storage = "com.osaurus.storage"
    /// API access keys (`APIKeyManager`).
    public static let accessKeys = "com.osaurus.access-keys"
    /// Hybrid address allowlist (`WhitelistStore`; the service string keeps
    /// the legacy name).
    public static let addressAllowlist = "com.osaurus.whitelist"
    /// Access-key revocations (`RevocationStore`).
    public static let revocations = "com.osaurus.revocations"
    /// Agent-scoped secrets (`AgentSecretsKeychain`).
    public static let agentSecrets = "ai.osaurus.agent-secrets"
    /// Plugin/tool secrets (`ToolSecretsKeychain`).
    public static let toolSecrets = "ai.osaurus.tools"
    /// MCP provider tokens and secrets (`MCPProviderKeychain`).
    public static let mcpProviders = "ai.osaurus.mcp"
    /// Remote model provider credentials (`RemoteProviderKeychain`).
    public static let remoteProviders = "ai.osaurus.remote"
    /// Search provider API keys (`SearchProviderKeychain`).
    public static let searchProviders = "ai.osaurus.search"
    /// Channel credentials (`ChannelCredentialVault`).
    public static let channels = "ai.osaurus.channels"
    /// Remote TTS API key (`TTSConfiguration`).
    public static let ttsRemote = "ai.osaurus.tts.remote"
    /// GitHub API token (`GitHubAuth`).
    public static let github = "com.dinoki.osaurus.github"
    /// Hugging Face access token (`HuggingFaceAuth`).
    public static let huggingFace = "com.dinoki.osaurus.huggingface"

    /// Everything factory reset must wipe.
    public static let all: [String] = [
        account,
        storage,
        accessKeys,
        addressAllowlist,
        revocations,
        agentSecrets,
        toolSecrets,
        mcpProviders,
        remoteProviders,
        searchProviders,
        channels,
        ttsRemote,
        github,
        huggingFace,
    ]
}
