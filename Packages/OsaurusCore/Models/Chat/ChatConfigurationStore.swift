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

    #if DEBUG
        /// Mutable only on `MainActor`; the unchecked conformance allows the
        /// reference to be carried as a task-local value while all access stays
        /// behind this actor-isolated store.
        private final class TestConfigurationBox: @unchecked Sendable {
            var configuration: ChatConfiguration

            init(_ configuration: ChatConfiguration) {
                self.configuration = configuration
            }
        }

        @TaskLocal private static var testConfiguration: TestConfigurationBox?

        /// Runs a test and its child tasks against an isolated in-memory chat
        /// configuration. This avoids process-global settings mutations between
        /// concurrently executing suites and never writes the user's settings.
        static func withTestConfiguration<T: Sendable>(
            _ configuration: ChatConfiguration,
            operation: @MainActor @Sendable () async throws -> T
        ) async rethrows -> T {
            let box = TestConfigurationBox(configuration)
            return try await $testConfiguration.withValue(box) {
                try await operation()
            }
        }
    #endif

    /// Load chat configuration from cache (no file I/O)
    /// File I/O is handled by AppConfiguration singleton
    public static func load() -> ChatConfiguration {
        #if DEBUG
            if let testConfiguration {
                return testConfiguration.configuration
            }
        #endif
        return AppConfiguration.shared.chatConfig
    }

    /// Save chat configuration to disk and update cache
    public static func save(_ configuration: ChatConfiguration) {
        #if DEBUG
            if let testConfiguration {
                testConfiguration.configuration = configuration
                return
            }
        #endif
        AppConfiguration.shared.updateChatConfig(configuration)
    }
}
