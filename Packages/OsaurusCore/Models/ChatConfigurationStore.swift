//
//  ChatConfigurationStore.swift
//  osaurus
//
//  Persistence for ChatConfiguration (Application Support bundle directory)
//  Now delegates to AppConfiguration for cached reads.
//

import Foundation

@MainActor
public enum ChatConfigurationStore {
    /// Optional directory override for tests
    public static var overrideDirectory: URL?

    /// Load chat configuration from cache (no file I/O)
    /// File I/O is handled by AppConfiguration singleton
    public static func load() -> ChatConfiguration {
        return AppConfiguration.shared.chatConfig
    }

    /// Save chat configuration to disk and update cache
    public static func save(_ configuration: ChatConfiguration) {
        AppConfiguration.shared.updateChatConfig(configuration)
    }
}
