// Copyright © 2026 osaurus.

import Foundation
import Testing

@Suite("Runtime source policy")
struct RuntimePolicySourceTests {
    private static func packageRoot() -> URL {
        let here = URL(fileURLWithPath: #filePath)
        var cursor = here.deletingLastPathComponent()  // Service/
        cursor.deleteLastPathComponent()  // Tests/
        return cursor.deletingLastPathComponent()  // OsaurusCore/
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = packageRoot().appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func functionBody(_ signature: String, in source: String) throws -> String {
        let start = try #require(source.range(of: signature))
        let peers = [
            "\n    private func ",
            "\n    private static func ",
            "\n    private nonisolated static func ",
            "\n    @Test",
        ]
        let end =
            peers.compactMap {
                source.range(of: $0, range: start.upperBound ..< source.endIndex)?.lowerBound
            }
            .min() ?? source.endIndex
        return String(source[start.lowerBound ..< end])
    }

    private static func vmlxPinRevision(in source: String) throws -> String {
        let location = try #require(source.range(of: "https://github.com/osaurus-ai/vmlx-swift"))
        let end = source.index(location.lowerBound, offsetBy: 800, limitedBy: source.endIndex) ?? source.endIndex
        let block = String(source[location.lowerBound ..< end])
        let regex = try NSRegularExpression(pattern: #""?revision"?\s*:\s*"([0-9a-f]{40})""#)
        let range = NSRange(block.startIndex ..< block.endIndex, in: block)
        let match = try #require(regex.firstMatch(in: block, range: range))
        let revisionRange = try #require(Range(match.range(at: 1), in: block))
        return String(block[revisionRange])
    }

    private static func swiftFiles(under relativePath: String) throws -> [URL] {
        let root = packageRoot().appendingPathComponent(relativePath)
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil
            )
        else {
            return []
        }

        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
            return url
        }
    }

    @Test("Makefile builds through workspace resolver mirrors")
    func makefileUsesWorkspaceResolver() throws {
        let source = try Self.source("../../Makefile")

        #expect(source.contains("WORKSPACE := osaurus.xcworkspace"))
        #expect(source.contains("XCODEBUILD_FLAGS ?="))
        #expect(source.contains("xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_CLI)"))
        #expect(source.contains("xcodebuild -workspace $(WORKSPACE) -scheme $(SCHEME_APP)"))
        #expect(source.contains("$(XCODEBUILD_FLAGS)"))
        #expect(
            !source.contains("xcodebuild -project $(PROJECT)"),
            "project-only builds bypass workspace SwiftPM mirrors and can resolve incompatible upstream pins"
        )
    }

    @Test("AppDelegate leaves DSV4 cache topology to vmlx")
    func appDelegateDoesNotForceDSV4DiagnosticCacheMode() throws {
        let source = try Self.source("AppDelegate.swift")

        #expect(
            !source.contains("setenv(\"DSV4_KV_MODE\""),
            "osaurus must not force DSV4_KV_MODE; unset keeps vmlx's SWA+CSA+HSA default"
        )
        #expect(
            !source.contains("DSV4_KV_MODE=full"),
            "full KV mode is diagnostic-only and drops DSV4 hybrid pool cache"
        )
        #expect(source.contains("SWA+CSA+HSA"))
    }

    @Test("AppDelegate starts storage-heavy embedding init off the main actor")
    func appDelegateDoesNotBlockServerStartupOnEmbeddingStorageInit() throws {
        let source = try Self.source("AppDelegate.swift")
        let toolIndex = try Self.source("Services/Tool/ToolIndexService.swift")

        #expect(source.contains("let embeddingInitTask = Task.detached(priority: .utility)"))
        #expect(source.contains("await serverController.startServer()"))
        #expect(source.contains("syncFromRegistry(rebuildVectorIndex: false)"))
        #expect(!source.contains("rebuildSearchIndexesInBackground()"))
        #expect(
            source.range(of: "let embeddingInitTask = Task {") == nil,
            "startup memory/vector initialization must not inherit MainActor and block server startup"
        )
        #expect(
            source.range(
                of:
                    "await ToolIndexService.shared.syncFromRegistry()\n            await SkillSearchService.shared.rebuildIndex()"
            ) == nil,
            "startup must not await the full VecturaKit tool/skill/method rebuild before health/API can respond"
        )
        let registerStart = try #require(toolIndex.range(of: "public func onToolRegistered("))
        let registerEnd = try #require(
            toolIndex.range(
                of: "/// Remove a tool from the index when unregistered",
                range: registerStart.upperBound ..< toolIndex.endIndex
            )
        )
        let registerBody = String(toolIndex[registerStart.lowerBound ..< registerEnd.lowerBound])
        #expect(registerBody.contains("ToolDatabase.shared.upsertEntry(entry)"))
        #expect(
            !registerBody.contains("ToolSearchService.shared.indexEntry"),
            "live tool registration must update the SQL/BM25 catalog without loading the embedding model on the launch path"
        )
    }

    @Test("Memory vector search skips vMLX embeddings while local model is resident")
    func memoryVectorSearchSkipsResidentMLXModel() throws {
        let source = try Self.source("Services/Memory/MemorySearchService.swift")

        #expect(source.contains("OSAURUS_DISABLE_MEMORY_VECTOR_SEARCH"))
        #expect(source.contains("ModelRuntime.shared.cachedModelSummaries()"))
        #expect(source.contains("residentModels.isEmpty"))
        #expect(source.contains("using SQL text fallback"))

        for operation in [
            "indexPinnedFact",
            "indexEpisode",
            "indexTranscriptTurn",
            "searchPinnedFacts",
            "searchEpisodes",
            "searchTranscript",
            "rebuildIndex",
        ] {
            #expect(
                source.contains("vectorWorkAllowed(\"\(operation)\")"),
                "MemorySearchService must guard \(operation) before VecturaKit/vMLX embedding work"
            )
        }
    }

    @Test("AppDelegate binds HTTP server before Parakeet/CoreML startup")
    func appDelegateStartsServerBeforeSpeechAutoload() throws {
        let source = try Self.source("AppDelegate.swift")
        let serverTask = try #require(source.range(of: "let serverStartupTask = Task { @MainActor in"))
        let serverStart = try #require(source.range(of: "await serverController.startServer()"))
        let storagePrewarm = try #require(source.range(of: "prewarmCurrentKeyOffCooperativeExecutor()"))
        let modelCachePrewarm = try #require(source.range(of: "await ModelPickerItemCache.shared.prewarmModelCache()"))
        let schedulerStart = try #require(source.range(of: "NextRunScheduler.shared.start()"))
        let speechAutoload = try #require(source.range(of: "await SpeechService.shared.autoLoadIfNeeded()"))

        #expect(serverTask.lowerBound < modelCachePrewarm.lowerBound)
        #expect(serverStart.lowerBound < schedulerStart.lowerBound)
        #expect(serverStart.lowerBound < speechAutoload.lowerBound)
        #expect(serverStart.lowerBound < storagePrewarm.lowerBound)
        #expect(source.contains("await serverStartupTask.value"))
        #expect(source.contains("MCPProviderManager.shared.connectEnabledProviders()"))
        #expect(source.contains("RemoteProviderManager.shared.connectEnabledProviders()"))
    }

    @Test("AppDelegate does not read the storage key before database opens")
    func appDelegateDoesNotReadStorageKeyBeforeDatabaseOpen() throws {
        let source = try Self.source("AppDelegate.swift")
        let firstDatabaseOpen = try #require(source.range(of: "try MemoryDatabase.shared.open()"))
        let storageGate = try #require(source.range(of: "StorageKeyManager.shared.hasCachedKey"))

        #expect(storageGate.lowerBound < firstDatabaseOpen.lowerBound)
        #expect(!source.contains("try? StorageKeyManager.shared.prewarmCurrentKey()"))
        #expect(source.contains("Task.detached(priority: .utility)"))
        #expect(source.contains("prewarmCurrentKeyOffCooperativeExecutor()"))
    }

    @Test("chat session list does not unlock storage key on init")
    func chatSessionListDoesNotUnlockStorageKeyOnInit() throws {
        let manager = try Self.source("Managers/Chat/ChatSessionsManager.swift")
        let initStart = try #require(manager.range(of: "private init() {"))
        let initEnd = try #require(
            manager.range(of: "    }\n\n    // MARK: - Public API", range: initStart.upperBound ..< manager.endIndex)
        )
        let initBody = String(manager[initStart.lowerBound ..< initEnd.upperBound])
        #expect(!initBody.contains("prewarmCurrentKeyOffCooperativeExecutor()"))

        let store = try Self.source("Models/Chat/ChatSessionStore.swift")
        #expect(store.contains("StorageKeyManager.shared.isStorageReadyForWrites"))
        #expect(store.contains("Chat history unavailable: storage key is not already unlocked"))
        #expect(!store.contains("prewarmCurrentKey()"))
        #expect(store.contains("Sentry APPLE-MACOS-40/41/42"))
    }

    @Test("chat history writer skips persistence unless storage key is already unlocked")
    func chatHistoryWriterSkipsPersistenceUnlessStorageKeyCached() throws {
        let source = try Self.source("Storage/ChatHistoryWriter.swift")
        let gate = try #require(source.range(of: "StorageKeyManager.shared.isStorageReadyForWrites"))
        let open = try #require(source.range(of: "try db.open()"))

        #expect(gate.lowerBound < open.lowerBound)
        #expect(source.contains("Skipping chat history persistence: storage key is not already unlocked"))
    }

    @Test("memory ingest fails fast when memory is disabled")
    func memoryIngestFailsFastWhenMemoryDisabled() throws {
        let source = try Self.source("Networking/HTTPHandler.swift")
        let disabledGate = try #require(source.range(of: "guard MemoryConfigurationStore.load().enabled else"))
        let waitForOpen = try #require(source.range(of: "MemoryDatabase.waitForSharedOpen(timeoutSeconds: 8)"))

        #expect(disabledGate.lowerBound < waitForOpen.lowerBound)
        #expect(source.contains(#""error":"memory_disabled""#))
        #expect(source.contains(#"errorMessage: "memory disabled""#))
    }

    @Test("scheduler startup does not unlock storage key")
    func schedulerStartupDoesNotUnlockStorageKey() throws {
        let source = try Self.source("AppDelegate.swift")
        let schedulerBlock = try #require(
            source.range(
                of: "Task { @MainActor in\n            guard StorageKeyManager.shared.isStorageReadyForWrites else"
            )
        )
        let schedulerStart = try #require(source.range(of: "NextRunScheduler.shared.start()"))

        #expect(schedulerBlock.lowerBound < schedulerStart.lowerBound)
        #expect(!source.contains("storageKeyPrewarmTask"))
        #expect(source.contains("Scheduler disabled: storage key is not already unlocked"))
    }

    @Test("storage key fails closed instead of minting a replacement over existing encrypted data")
    func storageKeyFailsClosedWhenEncryptedDataExists() throws {
        let source = try Self.source("Identity/StorageKeyManager.swift")

        // The fail-closed guard and its error must exist.
        #expect(source.contains("case keyUnavailableForExistingData"))
        #expect(source.contains("encryptedStorageExists()"))

        // The guard must sit *between* a missed key read and the
        // generate-and-persist fallback so a populated install can never re-key
        // itself and orphan the user's encrypted data.
        let readBranch = try #require(source.range(of: "let existing = try readKeychainKey()"))
        let failClosed = try #require(
            source.range(of: "throw StorageKeyError.keyUnavailableForExistingData")
        )
        let generate = try #require(source.range(of: "key = try generateAndPersistKey()"))
        #expect(readBranch.lowerBound < failClosed.lowerBound)
        #expect(failClosed.lowerBound < generate.lowerBound)

        // Existence is judged from real encrypted artifacts, not a single DB.
        #expect(source.contains("OsaurusPaths.chatHistoryDatabaseFile()"))
        #expect(source.contains("OsaurusPaths.memoryDatabaseFile()"))
    }

    @Test("startup avoids storage-key reads and background Keychain queries skip authentication UI")
    func startupAvoidsStorageKeyReadsAndBackgroundKeychainsSkipAuthenticationUI() throws {
        let storageKey = try Self.source("Identity/StorageKeyManager.swift")
        #expect(storageKey.contains("kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip"))
        #expect(storageKey.contains("cachedReadFailureStatus"))
        #expect(storageKey.contains("errSecInteractionNotAllowed"))
        #expect(storageKey.contains("public var hasCachedKey: Bool"))

        let appDelegate = try Self.source("AppDelegate.swift")
        // The storage key cache is warmed by an explicit prewarm that
        // must stay off the launch-critical main-actor path so a slow
        // Keychain read cannot prevent the local HTTP server from
        // binding.
        #expect(!appDelegate.contains("try? StorageKeyManager.shared.prewarmCurrentKey()"))
        #expect(appDelegate.contains("prewarmCurrentKeyOffCooperativeExecutor()"))
        #expect(appDelegate.contains("Task.detached(priority: .utility)"))
        #expect(appDelegate.contains("Storage-dependent search/index services disabled"))
        #expect(appDelegate.contains("guard StorageKeyManager.shared.hasCachedKey else"))

        let chatSessions = try Self.source("Managers/Chat/ChatSessionsManager.swift")
        #expect(!chatSessions.contains("prewarmCurrentKeyOffCooperativeExecutor()"))

        let apiKeys = try Self.source("Identity/APIKeyManager.swift")
        // The metadata blob now loads through the shared non-interactive store.
        #expect(apiKeys.contains("Keychain.read("))
        #expect(apiKeys.contains("private init() {}"))
        #expect(apiKeys.contains("private func ensureLoadedFromKeychain()"))
        #expect(!apiKeys.contains("private init() {\n        keys = Self.loadFromKeychain()"))

        let masterKey = try Self.source("Identity/MasterKey.swift")
        #expect(masterKey.contains("if context.interactionNotAllowed"))
        #expect(masterKey.contains("query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip"))

        let server = try Self.source("Networking/OsaurusServer.swift")
        #expect(server.contains("context.interactionNotAllowed = true"))
        #expect(server.contains("LazyAPIKeyValidatorSnapshot"))
        #expect(server.contains("apiKeyValidatorProvider: { validatorSnapshot.value() }"))
        #expect(!server.contains("let validator = Self.buildValidator"))

        let managementBadges = try Self.source("Managers/ManagementBadgeStore.swift")
        #expect(!managementBadges.contains("MasterKey.exists()"))
        #expect(managementBadges.contains("startup badges must not trigger"))

        let serverView = try Self.source("Views/Settings/ServerView.swift")
        #expect(!serverView.contains("if OsaurusIdentity.exists()"))
        #expect(!serverView.contains(".onAppear {\n            reloadAccessKeys()"))
        #expect(serverView.contains("reloadAccessKeys(readKeychain: true)"))
    }

    @Test("plugin host inference carries agent memory like HTTP chat")
    func pluginHostInferenceInjectsAgentMemoryPrefix() throws {
        let source = try Self.source("Services/Plugin/PluginHostAPI.swift")

        #expect(source.contains("let memorySection: String?"))
        #expect(source.contains("query: extractLatestUserQuery(from: messages)"))
        #expect(source.contains("messages: messages"))
        #expect(source.contains("memorySection: composed.memorySection"))
        // Memory rides the latest user message via the session-stable frozen
        // prefix path (KV-safe across requests), not a per-request injection
        // that vanishes from the next request's history.
        #expect(source.contains("SystemPromptComposer.applyFrozenMemoryPrefixes("))
        #expect(source.contains("memorySection: ctx.memorySection"))
        #expect(source.contains("frozen: frozenUserPrefixes"))
        #expect(source.contains("recordUserPrefix("))
        #expect(!source.contains("SystemPromptComposer.injectMemoryPrefix("))
    }

    @Test("plugin host inference defaults to a real tool loop")
    func pluginHostInferenceDefaultsToMultiIterationTools() throws {
        let source = try Self.source("Services/Plugin/PluginHostAPI.swift")

        #expect(
            source.contains("private static let defaultMaxIterations = 30"),
            "Plugin complete/complete_stream callers that omit max_iterations must get the same real multi-step budget as HTTP chat; Qwen-style tool/result loops can exceed a tiny default."
        )
        #expect(
            source.contains("private static let maxIterationsCap = 120"),
            "Plugin callers that explicitly request a deeper tool loop need headroom above the default without making the loop unbounded."
        )
        #expect(!source.contains("private static let defaultMaxIterations = 1"))
        #expect(!source.contains("private static let defaultMaxIterations = 8"))

        let chatConfig = try Self.source("Models/Chat/ChatConfiguration.swift")
        #expect(chatConfig.contains("maxToolAttempts: 30"))

        let http = try Self.source("Networking/HTTPHandler.swift")
        #expect(http.contains("await MainActor.run"))
        #expect(http.contains("ChatConfigurationStore.load().maxToolAttempts ?? 30"))
        #expect(http.contains("let maxIterations = max(1, min(configuredMaxToolAttempts, 120))"))
    }

    @Test("HTTP chat persistence runs after response path")
    func httpChatPersistenceRunsAfterResponsePath() throws {
        let source = try Self.source("Networking/HTTPHandler.swift")

        #expect(source.contains("ChatHistoryWriter.persistInBackground("))
        #expect(!source.contains("ChatHistoryWriter.persist(\n                            source: .http"))
    }

    @Test("chat session manager loads synchronously on init so first read sees populated sessions")
    func chatSessionManagerRefreshDoesNotSynchronouslyOpenHistoryOnInit() throws {
        let source = try Self.source("Managers/Chat/ChatSessionsManager.swift")
        let initStart = try #require(source.range(of: "private init() {"))
        let initEnd = try #require(
            source.range(of: "    }\n\n    // MARK: - Public API", range: initStart.upperBound ..< source.endIndex)
        )
        let initBody = source[initStart.lowerBound ..< initEnd.upperBound]

        // Synchronous load is the contract: `ChatWindowState.init` reads
        // `manager.sessions(for:)` immediately, and the Combine
        // subscription downstream drops its first emission, so any
        // deferred refresh strands the sidebar empty until the user
        // manually triggers a refresh.
        #expect(initBody.contains("sessions = ChatSessionStore.loadAll()"))
        #expect(!initBody.contains("Task { @MainActor [weak self] in"))
        #expect(!initBody.contains("prewarmCurrentKeyOffCooperativeExecutor()"))
    }

    @Test("remote provider autoconnect keeps Keychain reads off MainActor")
    func remoteProviderAutoconnectKeepsKeychainReadsOffMainActor() throws {
        let manager = try Self.source("Managers/RemoteProviderManager.swift")
        let connectStart = try #require(manager.range(of: "public func connect(providerId: UUID) async throws"))
        let disconnectStart = try #require(manager.range(of: "public func disconnect(providerId: UUID)"))
        let connectBody = String(manager[connectStart.lowerBound ..< disconnectStart.lowerBound])

        #expect(!connectBody.contains("provider.getOAuthTokens()"))
        #expect(!connectBody.contains("provider.resolvedHeaders()"))
        #expect(connectBody.contains("await provider.getOAuthTokensOffMainActor()"))
        #expect(connectBody.contains("await provider.resolvedHeadersOffMainActor()"))

        let service = try Self.source("Services/Provider/RemoteProviderService.swift")
        let fetchStart = try #require(
            service.range(of: "public static func fetchModels(from provider: RemoteProvider) async throws")
        )
        let decodeStart = try #require(service.range(of: "static func decodeOpenAICompatibleModelsResponse"))
        let fetchBody = String(service[fetchStart.lowerBound ..< decodeStart.lowerBound])

        #expect(!fetchBody.contains("provider.getOAuthTokens()"))
        #expect(!fetchBody.contains("provider.resolvedHeaders()"))
        #expect(fetchBody.contains("await provider.getOAuthTokensOffMainActor()"))
        #expect(fetchBody.contains("await provider.resolvedHeadersOffMainActor()"))
    }

    @Test("remote model snapshot timeout does not await a cancelled MainActor child")
    func remoteModelSnapshotTimeoutIsUnstructured() throws {
        let source = try Self.source("Networking/HTTPHandler.swift")
        let snapshot = try #require(source.range(of: "remoteOpenAIModelsSnapshot"))
        let show = try #require(source.range(of: "private func handleShowEndpoint"))
        let body = String(source[snapshot.lowerBound ..< show.lowerBound])

        #expect(
            !body.contains("withTaskGroup"),
            "`withTaskGroup` waits for cancelled children at scope exit, so it cannot timeout a MainActor task stuck in Keychain"
        )
        #expect(body.contains("CheckedContinuation"))
    }

    @Test("sandbox prompt lists secret IDs without decrypting secret values")
    func sandboxPromptListsSecretIDsWithoutDecryptingValues() throws {
        let keychain = try Self.source("Services/Keychain/AgentSecretsKeychain.swift")
        #expect(keychain.contains("public static func secretIDs(agentId: UUID) -> [String]"))

        let composer = try Self.source("Services/Chat/SystemPromptComposer.swift")
        let sandboxStart = try #require(
            composer.range(of: "if !effectiveToolsOff, executionMode.usesSandboxTools")
        )
        let sandboxEnd = try #require(
            composer.range(
                of: "} else if !effectiveToolsOff, let folder = executionMode.folderContext",
                range: sandboxStart.upperBound ..< composer.endIndex
            )
        )
        let sandboxBody = String(composer[sandboxStart.lowerBound ..< sandboxEnd.lowerBound])

        #expect(sandboxBody.contains("AgentSecretsKeychain.secretIDs(agentId: agentId)"))
        #expect(!sandboxBody.contains("AgentSecretsKeychain.getAllSecrets"))
    }

    @Test("background Keychain reads use noninteractive authentication contexts")
    func keychainReadsUseNonInteractiveAuthenticationContexts() throws {
        let helper = try Self.source("Services/Keychain/KeychainQueryHelpers.swift")
        #expect(helper.contains("context.interactionNotAllowed = true"))
        #expect(helper.contains("disablesKeychainForProcess"))

        for path in [
            "Services/Provider/RemoteProviderKeychain.swift",
            "Services/Keychain/AgentSecretsKeychain.swift",
            "Services/Keychain/ToolSecretsKeychain.swift",
            "Services/MCP/MCPProviderKeychain.swift",
        ] {
            let source = try Self.source(path)
            #expect(source.contains("if KeychainQueryHelpers.disablesKeychainForProcess"))
            let queryCount =
                source.components(separatedBy: "kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip").count
                - 1
            let contextCount =
                source.components(
                    separatedBy: "kSecUseAuthenticationContext as String: KeychainQueryHelpers.nonInteractiveContext()"
                ).count - 1
            #expect(contextCount >= queryCount)
        }

        // The shared store performs the actual reads for those wrappers, so it
        // must pair every UI-skip with a non-interactive authentication context.
        let store = try Self.source("Services/Keychain/Keychain.swift")
        let storeQueryCount =
            store.components(separatedBy: "kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip").count - 1
        let storeContextCount =
            store.components(
                separatedBy: "kSecUseAuthenticationContext as String: KeychainQueryHelpers.nonInteractiveContext()"
            ).count - 1
        #expect(storeQueryCount >= 1)
        #expect(storeContextCount >= storeQueryCount)

        let storageKey = try Self.source("Identity/StorageKeyManager.swift")
        #expect(storageKey.contains("kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip"))
        #expect(!storageKey.contains("KeychainQueryHelpers.nonInteractiveContext()"))
        #expect(storageKey.contains("if Self.disablesKeychainForProcess { return nil }"))
        #expect(storageKey.contains("if Self.disablesKeychainForProcess { return }"))
    }

    @Test("secret stores route through the shared legacy Keychain helper")
    func keychainWrappersUseSharedHelper() throws {
        // The credential + blob wrappers route every secret through the shared
        // Keychain helper rather than open-coding SecItem queries.
        for path in [
            "Services/Provider/RemoteProviderKeychain.swift",
            "Services/MCP/MCPProviderKeychain.swift",
            "Services/Keychain/ToolSecretsKeychain.swift",
            "Services/Keychain/AgentSecretsKeychain.swift",
            "Identity/APIKeyManager.swift",
            "Identity/WhitelistStore.swift",
            "Identity/RevocationStore.swift",
        ] {
            let source = try Self.source(path)
            #expect(
                source.contains("Keychain."),
                "\(path) must route secrets through the shared Keychain helper"
            )
        }

        // The restricted keychain-access-groups entitlement must stay out of the
        // Developer ID build: it requires a provisioning profile we don't ship,
        // so its presence makes AMFI kill the app at launch.
        let entitlements = try Self.source("../../App/osaurus/osaurus.entitlements")
        #expect(!entitlements.contains("keychain-access-groups"))
    }

    @Test("ServerController relies on NIO bind instead of a startup port probe")
    func serverControllerDoesNotPreflightPortWithNetworkConnection() throws {
        let source = try Self.source("Networking/ServerController.swift")

        #expect(!source.contains("import Network"))
        #expect(!source.contains("NWConnection"))
        #expect(!source.contains("isAnyListenerActive"))
        #expect(source.contains("try await server.start("))
        #expect(
            source.contains("\"Port \\(configuration.port) is already in use. Choose a different port in Settings.\"")
        )
    }

    @Test("HTTP server does not close long local inference for NIO idle timeout")
    func osaurusServerDoesNotInstallNIOIdleTimeoutForInferenceChannels() throws {
        let source = try Self.source("Networking/OsaurusServer.swift")
        let initializerStart = try #require(source.range(of: ".childChannelInitializer { channel in"))
        let initializerEnd = try #require(
            source.range(of: ".childChannelOption", range: initializerStart.upperBound ..< source.endIndex)
        )
        let initializer = String(source[initializerStart.lowerBound ..< initializerEnd.lowerBound])

        #expect(initializer.contains("ConnectionLimitHandler()"))
        #expect(initializer.contains("HTTPHandler("))
        #expect(!initializer.contains("IdleStateHandler("))
        #expect(!initializer.contains("writeTimeout:"))
        #expect(!initializer.contains("allTimeout:"))
        #expect(
            initializer.contains("long local non-streaming"),
            "source comment should preserve why NIO idle timeouts break slow local /v1/chat/completions"
        )
    }

    @Test("vmlx pin uses consolidated package with runtime hardening")
    func vmlxPinIncludesRuntimeHardening() throws {
        let manifest = try Self.source("Package.swift")
        let workspaceResolved = try Self.source(
            "../../osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        let appResolved = try Self.source(
            "../../App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )

        // The synchronized revision keeps the consolidated vmlx-swift pin for Osaurus
        // with vendored Jinja/Hub/Tokenizers/Transformers exposed through
        // VMLX-prefixed products, plus the Qwen3.6 MXFP affine metadata,
        // MoE router-gate load hardening, native-MTP speedup proof gate,
        // parser override load bridge, complete SSM companion-cache guard,
        // Qwen3.6 native-MTP alias recognition, and expanded loaded
        // cache-topology snapshotting for server-side cache autodetect, and
        // quantization-bound native-MTP tuning for MXFP8 launch safety, and
        // ZAYA1-VL reasoning-parser fallback separation, tuned native-MTP
        // server autodetect by default, and MXFP8 artifact-evidence tuning
        // acceptance, plus DSV4 DSML tool protocol hardening for no-arg
        // invokes, schema-valid and schema-less inline JSON fallback,
        // malformed JSON-shaped tool-attempt quarantine, and truncated
        // schema-less JSON tool-attempt quarantine at EOS, plus live
        // bare-name key/value DSV4 tool attempts such as
        // `file_read\npath=...` being parsed as tools instead of visible text,
        // and Qwen multi-turn tool/cache matrix coverage staying present in
        // the vMLX regression harness, plus the Nemotron Omni tool-template
        // fallback that keeps tool schemas rendered through the model-native
        // [AVAILABLE_TOOLS]/XML function-call contract instead of leaking
        // role-token/DSML fragments in Osaurus tool turns, plus the Gemma4
        // Zyphra XML tool-call parser used by live JANG_4M multiline tool
        // envelopes, plus Gemma4 unified 12B config dispatch, processor
        // tool-schema preservation, quoted native call:value parsing, the
        // explicit unsupported boundary for unproven unified image/audio/video,
        // and Gemma4 proportional RoPE support needed by full-attention layers,
        // plus safe auto-enabled Nemotron Ultra JANGTQ streaming dispatch that
        // avoids full expert materialization for 512-expert stacked-only models,
        // with Nemotron Ultra BF16 activation retention, weighted MoE
        // fast-path controls wired behind explicit disable env vars, and the
        // native Nemotron XML tool fallback preserving required parameter
        // metadata for strict tool choice, plus the Nemotron Ultra resident
        // perf harness load split and mmap growing-cache proof for
        // disk-backed hybrid SSM companion hits, plus the Nemotron Ultra
        // mamba_projection role alias so Osaurus auto-settings consume the
        // same 8-bit affine Mamba projection metadata as mamba_proj-stamped
        // bundles, plus the Nemotron-H JANGTQ mmap auto-BF16 load path that
        // keeps TQ tensors raw while promoting non-TQ tensors out of fp16
        // AsType-heavy decode, plus streamed DSV4 request-tool prefix
        // buffering, the Gemma4 native tool-call parser regression pin,
        // generation-config suppress_tokens propagation, seed-boundary
        // hybrid SSM full-hit restore, Nemotron-H Mamba cache-offset and
        // SSM dtype parity, the stacked Nemotron JANGTQ scored
        // down-projection kernel kept opt-in after live Ultra rows showed it
        // regresses the default decode path, and the Gemma native tool-call
        // parser/cache hardening plus LFM/ZAYA cache proof pins carried by
        // the current vMLX runtime branch, including stale ZAYA tool-template
        // shim detection so tagged but non-choice-aware local templates do not
        // bypass required-tool handling, the LFM required-tool solo
        // disk-restore skip plus schema-validated Pythonic parser hardening,
        // and the cross-target MLX test lock that prevents the Gemma4
        // audio/media/cache source proof from crashing under Swift Testing,
        // and the Gemma4 required-tool template ordering fix that keeps
        // preserving-newlines user content as the final model-visible copy
        // target before generation, plus the memory-safety resolver fix that
        // preserves explicit disabled prefix-cache settings and disables
        // dependent paged-KV/block-disk cache topology instead of forcing the
        // default cache stack back on,
        // plus the DiffusionGemma MoE-router crash fix that dequantizes the
        // QuantizedEmbedding tied head before the soft self-conditioning
        // matmul so the 26B-A4B diffusion router no longer traps (SIGTRAP)
        // on denoising step >= 2,
        // plus the slider-aware KV/context cap with TurboQuant-inform
        // over-budget warning, the Gemma tool-path prose de-scramble
        // (ToolCallProcessor bare-call buffer + whitespace-leading fix), the
        // SWA/rotating warm prefix-cache reuse that skips re-prefill on a full
        // hit (narrowed to standalone rotating windows only), and the
        // matching prefix-hit diagnostics that count disk-tier reuse.
        // That avoids Xcode PIF
        // duplicate-product collisions with the app graph while keeping yyjson
        // as one shared C dependency. Osaurus must not carry SwiftPM
        // moduleAliases for that collision.
        // plus the quadratic-BPE merge fix (O(n^2) -> O(n log n) on long
        // whitespace-free pre-tokens) that collapses multi-second prefill on
        // tool-heavy prompts while staying byte-identical to canonical output
        // even on non-monotonic whitespace merge ranks,
        // plus the Gemma nested-object tool-call argument parse fix
        // (vmlx-swift#76): GemmaFunctionParser now recurses into `{...}` values
        // so object-typed tool parameters arrive as objects, not raw strings.
        // plus vmlx-swift#82: BatchEngine drains the GPU (Stream().synchronize)
        // before finishing the stream so the chat→image handoff cannot race the
        // async eval tail (fixes the concurrent-GPU SIGSEGV/commit-assert), and
        // JangLoader loads a standalone chat_template.jinja when
        // tokenizer_config.json carries no inline template (fixes empty output
        // on LFM2.5 + VibeThinker bundles),
        // plus vmlx-swift#84: Mistral3/Pixtral VLM bundles in the standard
        // Hugging Face layout (flat top-level rope_theta, and image-processor
        // params split across preprocessor_config.json + processor_config.json)
        // now load instead of fatally crashing at model-load — the language
        // attention falls back to flat rope_theta and the processor config
        // accepts both nested and flat image-processor layouts (fixes the
        // Sentry EXC_BREAKPOINT on Mistral-Small / Ministral / Pixtral).
        // plus vmlx-swift#104: ImageIO.writePNG dropped its needless @MainActor
        // isolation, so the MLX eval() it triggers no longer blocks the main
        // thread during image generation (fixes the Sentry App Hanging report
        // in ZImage.performGenerate).
        // plus the deterministic-load checkpoint: the shared RMSNorm
        // convention resolver (vmlx-swift#102) and the full
        // order-dependent-load sweep (vmlx-swift#108) that remove every
        // per-process-random Dictionary/Set-order load decision (no more
        // ~7.5% "degenerates until reload" loads), the Mistral3 VLM fix
        // (vmlx-swift#107) that honors the bundle's longest_edge instead of
        // crushing images to 336px, and the stop-string fix (vmlx-swift#109)
        // that discards post-stop buffers at end-of-stream so text after a
        // matched stop string can no longer leak into responses,
        // plus the orphan tool-call closer strip (vmlx-swift#115) that
        // removes stray `</parameter></function></zyphra_tool_call>`
        // closer runs from the visible stream in ZAYA / Gemma-4
        // AppleScript agent-loop rows.
        let expectedRuntimeHardenedRevision = "8dffa0a8e69d7617d68f0843635158684120a3dc"
        let manifestRevision = try Self.vmlxPinRevision(in: manifest)
        let workspaceRevision = try Self.vmlxPinRevision(in: workspaceResolved)
        let appRevision = try Self.vmlxPinRevision(in: appResolved)
        #expect(manifestRevision == workspaceRevision)
        #expect(manifestRevision == appRevision)
        #expect(
            manifestRevision == expectedRuntimeHardenedRevision,
            "Osaurus must consume the pushed vmlx-swift revision proven for this Gemma QAT correctness checkpoint: Gemma 4 QAT loader/parser fixes, paged-cache default policy, prefill progress wiring, Model2Vec static embedding APIs, and the post-merge pin/readiness proof. An internally-consistent older pin is still not wired"
        )
        #expect(manifest.contains("https://github.com/osaurus-ai/vmlx-swift"))
        #expect(!manifest.contains("https://github.com/osaurus-ai/vmlx-swift-lm"))
        #expect(!manifest.contains("https://github.com/osaurus-ai/mlx-swift"))
        #expect(!manifest.contains("https://github.com/osaurus-ai/swift-transformers"))
        #expect(!manifest.contains("https://github.com/osaurus-ai/Jinja.git"))
        #expect(manifest.contains(".product(name: \"MLX\", package: \"vmlx-swift\")"))
        #expect(manifest.contains(".product(name: \"MLXLLM\", package: \"vmlx-swift\")"))
        #expect(manifest.contains(".product(name: \"MLXVLM\", package: \"vmlx-swift\")"))
        #expect(manifest.contains(".product(name: \"MLXLMCommon\", package: \"vmlx-swift\")"))
        #expect(manifest.contains(".product(name: \"VMLXTokenizers\", package: \"vmlx-swift\")"))
        #expect(manifest.contains(".product(name: \"VMLXJinja\", package: \"vmlx-swift\")"))
    }

    @Test("new model loads forward caller cancellation into loader task")
    func modelRuntimeNewLoadsCancelUnderlyingLoaderTask() throws {
        let source = try Self.source("Services/ModelRuntime.swift")
        let taskStart = try #require(source.range(of: "let task = Task<SessionHolder, Error>"))
        let taskStore = try #require(
            source.range(of: "loadingTasks[name] = LoadingTaskRecord(id: loadID, task: task)")
        )
        let success = try #require(
            source.range(of: "return try await finishLoadedContainer", range: taskStore.upperBound ..< source.endIndex)
        )
        let loadBody = String(source[taskStart.lowerBound ..< success.lowerBound])

        #expect(loadBody.contains("withTaskCancellationHandler"))
        #expect(loadBody.contains("try await task.value"))
        #expect(loadBody.contains("onCancel:"))
        #expect(loadBody.contains("cancelLoadingTask(name: name, loadID: loadID)"))
        #expect(source.contains("private func cancelLoadingTask(name: String, loadID: UInt64) async"))
        #expect(source.contains("await cancelAndDrainLoadingTasks([(name, record)]"))
    }

    @Test("cancelled cold load is unloaded before stream setup")
    func cancelledColdLoadUnloadsBeforeStreamSetup() throws {
        let source = try Self.source("Services/ModelRuntime.swift")
        let loadDone = try #require(source.range(of: #"trace?.mark("load_container_done")"#))
        let leaseAcquire = try #require(
            source.range(
                of: "await ModelLease.shared.acquire(modelName)",
                range: loadDone.upperBound ..< source.endIndex
            )
        )
        let postLoadWindow = String(source[loadDone.lowerBound ..< leaseAcquire.lowerBound])

        #expect(postLoadWindow.contains("if Task.isCancelled"))
        #expect(postLoadWindow.contains("await ModelResidencyManager.shared.cancel(modelName: modelName)"))
        #expect(postLoadWindow.contains("if shouldReportModelLoad"))
        #expect(postLoadWindow.contains("await unload(name: modelName)"))
        #expect(postLoadWindow.contains("throw CancellationError()"))
    }

    @Test("DSV4 renderer checklist keeps invalid generic flags out of CLI preview")
    func dsv4RendererChecklistTracksInvalidGenericFlags() throws {
        let switchDoc = try Self.source("../../docs/VMLX_SWIFT_SINGLE_PACKAGE_SWITCH_2026_05_18.md")
        let runtimeDoc = try Self.source("../../docs/INFERENCE_RUNTIME.md")
        let liveMatrix = try Self.source("../../docs/VMLX_SWIFT_OSAURUS_LIVE_MATRIX_2026_05_18.md")

        for required in [
            "native DSV4 cache copy",
            "SWA+CSA+HSA",
            "DeepseekV4Cache",
            "block-size control is fixed/disabled at 256",
            "generic KV q4/q8 controls are disabled",
            "pool quant state is visible",
            "JIT is disabled",
            "generation defaults shown in the UI come from model metadata",
        ] {
            #expect(switchDoc.contains(required), "missing DSV4 renderer requirement: \(required)")
        }

        for required in [
            "native DSV4 cache copy present",
            "block size fixed/disabled at 256",
            "generic KV q4/q8 disabled",
            "pool quant visible",
            "JIT disabled",
            "generation defaults shown from `generation_config.json` / `jang_config.json` metadata",
        ] {
            #expect(liveMatrix.contains(required), "missing live matrix DSV4 renderer requirement: \(required)")
        }

        for invalidFlag in [
            "--kv-cache-quantization",
            "--enable-jit",
            "--is-mllm",
            "--speculative-model",
        ] {
            #expect(switchDoc.contains(invalidFlag))
            #expect(runtimeDoc.contains(invalidFlag))
            #expect(liveMatrix.contains(invalidFlag))
        }

        #expect(switchDoc.contains("fake sampler clamps"))
        #expect(switchDoc.contains("forced repetition penalties"))
        #expect(switchDoc.contains("Forced behavior cleanup is part of the switch"))
        #expect(switchDoc.contains("forced `</think>` close"))
        #expect(switchDoc.contains("token/logit shaping"))
        #expect(switchDoc.contains("generic cache"))
    }

    @Test("vmlx switch does not commit PR1147 live-gate artifacts")
    func vmlxSwitchDoesNotCommitPR1147LiveGateArtifacts() throws {
        let repoRoot = Self.packageRoot()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let bannedRelativePaths = [
            "docs/internal/live-gates",
            "scripts/pr1147_collect_bundle_census.py",
            "scripts/pr1147_http_route_probe.py",
            "scripts/pr1147_keychain_safe_app_launch.sh",
            "scripts/pr1147_live_sequence_probe.py",
            "scripts/tests/test_pr1147_live_sequence_probe.py",
        ]

        for relativePath in bannedRelativePaths {
            let url = repoRoot.appendingPathComponent(relativePath)
            #expect(
                !FileManager.default.fileExists(atPath: url.path),
                "\(relativePath) is a private PR1147 live-gate artifact and must not be committed"
            )
        }
    }

    @Test("SwiftPM graph keeps vmlx inference modules unshadowed")
    func swiftPMGraphUsesConsolidatedVMLXRuntime() throws {
        let manifest = try Self.source("Package.swift")
        let workspaceMirrors = try Self.source(
            "../../osaurus.xcworkspace/xcshareddata/swiftpm/configuration/mirrors.json"
        )
        let appProjectMirrors = try Self.source(
            "../../App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration/mirrors.json"
        )
        let contributing = try Self.source("../../docs/CONTRIBUTING.md")

        let tokenizerLoader = try Self.source(
            "Services/ModelRuntime/SwiftTransformersTokenizerLoader.swift"
        )
        let jinjaTests = try Self.source("Tests/Service/JinjaTemplateCompatibilityTests.swift")
        let acknowledgements = try Self.source("../../App/osaurus/Acknowledgements.json")
        let acknowledgementFallback = try Self.source("Views/Management/AcknowledgementsView.swift")
        let acknowledgementGenerator = try Self.source("../../scripts/release/generate_acknowledgements.py")

        #expect(!manifest.contains("vmlxRuntimeModuleAliases"))
        #expect(!manifest.contains("moduleAliases:"))
        #expect(manifest.contains("https://github.com/mattt/eventsource.git"))
        #expect(manifest.contains("traits: [.trait(name: \"AsyncHTTPClient\")]"))
        #expect(!manifest.contains("https://github.com/ibireme/yyjson.git"))
        #expect(manifest.contains(".product(name: \"MCP\", package: \"swift-sdk\")"))
        #expect(manifest.contains(".product(name: \"VecturaKit\", package: \"VecturaKit\")"))
        #expect(tokenizerLoader.contains("import VMLXTokenizers"))
        #expect(!tokenizerLoader.contains("import Tokenizers"))
        #expect(jinjaTests.contains("import VMLXJinja"))
        #expect(!jinjaTests.contains("import Jinja"))

        for mirrors in [workspaceMirrors, appProjectMirrors] {
            #expect(mirrors.contains("\"original\" : \"https://github.com/huggingface/swift-transformers\""))
            #expect(mirrors.contains("\"original\" : \"https://github.com/huggingface/swift-transformers.git\""))
            #expect(mirrors.contains("\"mirror\" : \"https://github.com/osaurus-ai/swift-transformers\""))
            #expect(mirrors.contains("\"original\" : \"https://github.com/huggingface/swift-jinja\""))
            #expect(mirrors.contains("\"original\" : \"https://github.com/huggingface/swift-jinja.git\""))
            #expect(mirrors.contains("\"mirror\" : \"https://github.com/osaurus-ai/Jinja.git\""))
            #expect(!mirrors.contains("vmlx-swift"))
            #expect(!mirrors.contains("/Users/eric/vmlx-swift"))
        }

        #expect(contributing.contains("single consolidated `vmlx-swift` pin"))
        #expect(contributing.contains("prefixed inside `vmlx-swift`"))
        #expect(contributing.contains("Keep the two mirror files in sync"))

        for generatedText in [acknowledgements, acknowledgementFallback, acknowledgementGenerator] {
            #expect(generatedText.contains("vmlx-swift"))
            #expect(!generatedText.contains("mlx-swift-lm"))
            #expect(!generatedText.contains("\"identity\": \"mlx-swift\""))
        }
        #expect(acknowledgementGenerator.contains("script_dir.parent.parent"))
    }

    @Test("Current runtime docs name consolidated vmlx-swift package")
    func currentRuntimeDocsDoNotTeachOldPackageGraph() throws {
        for docPath in [
            "../../docs/OpenAI_API_GUIDE.md",
            "../../docs/FEATURES.md",
            "../../docs/DEVELOPER_TOOLS.md",
            "../../docs/MODEL_COMPATIBILITY_RESEARCH.md",
            "../../docs/MODEL_IDLE_RESIDENCY_SPEC.md",
            "../../docs/INFERENCE_RUNTIME.md",
        ] {
            let doc = try Self.source(docPath)
            #expect(!doc.contains("vmlx-swift-lm"), "\(docPath) still names the retired direct inference package")
        }
    }

    @Test("Current runtime source comments name consolidated vmlx-swift package")
    func currentRuntimeSourcesDoNotTeachOldPackageGraph() throws {
        for relativePath in [
            "Package.swift",
            "AppDelegate.swift",
        ] {
            let source = try Self.source(relativePath)
            #expect(
                !source.contains("vmlx-swift-lm"),
                "\(relativePath) still names the retired direct inference package"
            )
            #expect(
                !source.contains("mlx-swift-lm"),
                "\(relativePath) still names the retired direct inference package"
            )
        }

        for relativePath in [
            "Models",
            "Services",
            "Utils",
            "Views",
            "Managers",
        ] {
            for url in try Self.swiftFiles(under: relativePath) where !url.path.contains("/.build/") {
                let source = try String(contentsOf: url, encoding: .utf8)
                #expect(
                    !source.contains("vmlx-swift-lm"),
                    "\(url.path) still names the retired direct inference package"
                )
                #expect(
                    !source.contains("mlx-swift-lm"),
                    "\(url.path) still names the retired direct inference package"
                )
            }
        }
    }

    @Test("Osaurus source does not import unvendored tokenizer or template modules")
    func osaurusSourceUsesVMLXPrefixedTokenizerAndTemplateModules() throws {
        let disallowedImports = [
            "import Tokenizers",
            "import Jinja",
            "import Hub",
            "import Transformers",
        ]

        for url in try Self.swiftFiles(under: ".") where !url.path.contains("/.build/") {
            let source = try String(contentsOf: url, encoding: .utf8)
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                #expect(
                    !disallowedImports.contains(trimmed),
                    "\(url.path) imports \(trimmed); use the VMLX-prefixed products from vmlx-swift"
                )
            }
        }
    }

    /// Lock the post-generation SSM re-derive opt-out. vmlx defaults
    /// `enableSSMReDerive=true`. Pre-`b9da180` this ran a FULL second
    /// prefill BEFORE yielding `.info` (the Ling stuck-before-end
    /// symptom). vmlx pin `b9da180` reordered the pass to run AFTER
    /// `.info`, fixing the stream-stays-open UX. Keep this default on so
    /// hybrid SSM/linear-attention cache rows have their companion state
    /// rederived and stored by default instead of silently falling back to
    /// KV-only reuse.
    @Test("CacheCoordinatorConfig enables SSM re-derive for automatic hybrid cache reuse")
    func cacheConfigEnablesSSMReDerive() throws {
        // Ownership moved from `ModelRuntime.buildCacheCoordinatorConfig`
        // (which now delegates to `VMLXServerRuntimeSettings.cacheCoordinatorConfig`)
        // to `ServerRuntimeSettingsStore.migratedFromLegacy`. The
        // migrated default seeds `enableSSMReDerive: true` so Osaurus does
        // not default hybrid models into KV-only cache reuse.
        let store = try Self.source("Models/Configuration/ServerRuntimeSettingsStore.swift")

        #expect(
            store.contains("enableSSMReDerive: true"),
            "ServerRuntimeSettingsStore.migratedFromLegacy must seed enableSSMReDerive=true for automatic hybrid cache reuse"
        )
        #expect(
            store.contains("liveKVCodec: .engineSelected"),
            "ServerRuntimeSettingsStore.migratedFromLegacy must use engine-selected live KV so proven full-KV rows default to TurboQuant"
        )
        #expect(
            store.contains("pagedKV: VMLXPagedKVCacheSettings(\n                enabled: false"),
            "ServerRuntimeSettingsStore.migratedFromLegacy must keep paged RAM KV off by default"
        )
        #expect(
            store.contains("shouldRepairPagedCacheDefault"),
            "ServerRuntimeSettingsStore must repair stale persisted paged-cache default files to off"
        )
        #expect(
            !store.contains("normalized.cache.liveKVCodec = .engineSelected"),
            "Legacy cache migration must not overwrite explicit existing live-KV choices"
        )
        #expect(
            store.contains("Engine-selected live KV is resolved by ModelRuntime per"),
            "ServerRuntimeSettingsStore must document that engine-selected is topology-gated by ModelRuntime"
        )
        #expect(
            store.contains("shouldRepairLegacyCacheDefaults"),
            "ServerRuntimeSettingsStore must still repair stale persisted hybrid cache companion defaults"
        )
        let runtime = try Self.source("Services/ModelRuntime.swift")
        #expect(
            runtime.contains("shouldUseTurboQuantByDefault"),
            "ModelRuntime must own the engine-selected TurboQuant gate"
        )
        // POLICY (2026-06-12): TurboQuant KV is never auto-enabled for ANY
        // family. shouldUseTurboQuantByDefault must unconditionally return
        // false so engineSelected resolves to native fp16 everywhere; the
        // per-step compress/decompress tax regresses decode across families
        // (Gemma 26B-A4B -42%, 12B -29%). TQ is opt-in only via explicit
        // liveKVCodec=turboQuant.
        #expect(
            runtime.contains("Eric directive 2026-06-12")
                && runtime.contains("TurboQuant KV is NEVER enabled")
                && runtime.contains("liveKVCodec=turboQuant"),
            "shouldUseTurboQuantByDefault must document and enforce the blanket TurboQuant-off-by-default policy"
        )
        // The function must NOT reintroduce a family/topology branch that can
        // return true (which is what silently force-enabled TurboQuant before).
        #expect(
            !runtime.contains("return cacheTopology.kvLayerCount > 0")
                && !runtime.contains("return ModelFamilyNames.isMiniMaxFamily(modelName)"),
            "shouldUseTurboQuantByDefault must not auto-select TurboQuant for full-KV families (MiniMax) or KV-bearing topologies"
        )
        let mlxService = try Self.source("Services/Inference/MLXService.swift")
        #expect(
            mlxService.contains("ModelFamilyNames.isStepFamily(modelId)")
                && mlxService.contains("Step 3.7 currently runs through vMLX's Step text runtime")
                && mlxService.contains("Step 3.7 tool parsing/template selection is owned by the pinned")
                && mlxService.contains("return ModelMediaCapabilities.descriptor(modelId: modelId)"),
            "Step 3.7 runtime policy must stay text-only/tool-capable and must not block preflight on external bundle metadata until Step VLM is wired and proven"
        )
    }

    @Test("Runtime cache telemetry keeps paged-prefix and disk-L2 counters separate")
    func cacheTelemetryDoesNotFoldDiskL2IntoPrefixCounters() throws {
        let httpHandler = try Self.source("Networking/HTTPHandler.swift")
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")

        #expect(httpHandler.contains(#""paged_cache""#))
        #expect(httpHandler.contains(#""block_disk_store""#))
        #expect(httpHandler.contains(#""disk_l2_hits""#))
        #expect(httpHandler.contains(#""prefix_hits""#))
        #expect(httpHandler.contains(#""companion_cache""#))
        #expect(httpHandler.contains(#""zaya_cca_disk_payload_restore""#))
        #expect(httpHandler.contains(#""zaya_cca_disk_payload_hits""#))
        #expect(httpHandler.contains(#"let hasSSMCompanion = companionKinds.contains("companion=ssm")"#))
        #expect(httpHandler.contains("if hasSSMCompanion"))
        #expect(!httpHandler.contains(#""zaya_cca_companion_cache""#))
        #expect(!httpHandler.contains(#""zaya_cca_companion_hits""#))
        #expect(httpHandler.contains(#""cache_topology""#))
        #expect(httpHandler.contains("hybrid_pool_layer_count"))
        #expect(httpHandler.contains("zaya_cca_layer_count"))
        #expect(httpHandler.contains("requires_disk_backed_restore"))
        #expect(!httpHandler.contains(#"aggregate["prefix_hits", default: 0] += diskStats.hits"#))
        #expect(!httpHandler.contains(#"aggregate["prefix_misses", default: 0] += diskStats.misses"#))

        #expect(adapter.contains("diskL2Hits += diskStats.hits"))
        #expect(adapter.contains("diskL2Misses += diskStats.misses"))
        #expect(!adapter.contains("prefixHits += diskStats.hits"))
        #expect(!adapter.contains("prefixMisses += diskStats.misses"))

        let cacheSection = try Self.source("Views/Settings/ServerSettings/CacheSection.swift")
        #expect(cacheSection.contains(#"value: $draft.cache.blockDisk.directory"#))
        #expect(cacheSection.contains(#"value: $draft.cache.legacyDisk.directory"#))
    }

    @Test("Server settings cache changes clear loaded model runtime")
    func cacheSettingsChangesClearLoadedModelRuntime() throws {
        let controller = try Self.source("Networking/ServerController.swift")

        #expect(controller.contains("loadedModelRuntimeInputsRequireRefresh"))
        #expect(controller.contains("previous.cache != next.cache"))
        #expect(controller.contains("previous.multimodal != next.multimodal"))
        #expect(controller.contains("previous.mtp != next.mtp"))
        #expect(controller.contains("await ModelRuntime.shared.clearAll()"))
    }

    @Test("Server settings concurrency UI does not advertise false restart or runtime wiring")
    func serverSettingsConcurrencyUIDoesNotAdvertiseFalseRestartOrRuntimeWiring() throws {
        let tab = try Self.source("Views/Settings/ServerSettingsTabContent.swift")
        let concurrency = try Self.source("Views/Settings/ServerSettings/ConcurrencySection.swift")

        guard let restartStart = tab.range(of: "private var pendingRestart: Bool"),
            let restartEnd = tab.range(
                of: "private var hasUnsavedChanges: Bool",
                range: restartStart.lowerBound ..< tab.endIndex
            )
        else {
            Issue.record("Could not locate pendingRestart in ServerSettingsTabContent.swift")
            return
        }
        let pendingRestart = tab[restartStart.lowerBound ..< restartEnd.lowerBound]
        #expect(!pendingRestart.contains("concurrency.maxConcurrentSequences"))

        #expect(concurrency.contains("`maxConcurrentSequences` hot-resizes"))
        #expect(concurrency.contains("runtime consumers for these fields are not yet implemented"))
        #expect(concurrency.contains("pins the BatchEngine to one active slot"))
        #expect(concurrency.contains("Concurrent Sessions"))
        #expect(concurrency.contains("Continuous Batching"))
        #expect(concurrency.contains("Prompt Prefill Chunk Size"))
    }

    @Test("Tools settings panel separates wired parser overrides from planned host bridges")
    func toolsSettingsPanelSeparatesWiredParserOverridesFromPlannedHostBridges() throws {
        let toolsSection = try Self.source("Views/Settings/ServerSettings/ToolsTemplatesSection.swift")
        let runtime = try Self.source("Services/ModelRuntime.swift")

        #expect(toolsSection.contains("status: .partial"))
        #expect(!toolsSection.contains("status: .engineReady"))
        #expect(toolsSection.contains("Parser overrides are applied at model load"))
        #expect(toolsSection.contains("Applied by vmlx at local model load"))
        #expect(toolsSection.contains("Implicit tool-choice policy is persisted only"))
        #expect(toolsSection.contains("MCP config-file override is persisted only"))
        #expect(toolsSection.contains("Custom chat templates are persisted only"))

        #expect(runtime.contains("resolvedModelConfiguration("))
        #expect(runtime.contains("ServerRuntimeSettingsStore.snapshot()"))
    }

    @Test("Server model-load cache setup uses loaded vmlx topology, not only name heuristics")
    func modelLoadCacheSetupUsesLoadedVMLXTopologySnapshot() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")

        #expect(runtime.contains("await holder.container.cacheTopologySnapshot()"))
        #expect(runtime.contains("cacheTopology: cacheTopology"))
        #expect(runtime.contains("await holder.container.enableCachingAsync(config: cacheConfig)"))
        #expect(!runtime.contains("holder.container.enableCaching(config: cacheConfig)"))
        #expect(!runtime.contains("holder.container.cacheCoordinator?.setHybrid(true)"))
    }

    @Test("Flexible model residency respects load-time memory budget")
    func flexibleModelResidencyEvictsBeforeOversizedLoads() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")
        let serverConfig = try Self.source("Models/Configuration/ServerConfiguration.swift")
        let runtimeSettings = try Self.source("Models/Configuration/ServerRuntimeSettingsStore.swift")

        #expect(runtime.contains("flexibleResidentBudgetBytes"))
        #expect(serverConfig.contains("defaultModelLoadRAMSoftThreshold"))
        #expect(serverConfig.contains("defaultModelLoadRAMHardThreshold"))
        #expect(runtimeSettings.contains("modelLoadRAMThresholds()"))
        #expect(runtime.contains("unloadForFlexibleResidentBudget"))
        #expect(runtime.contains("policy == .manualMultiModel"))
        #expect(runtime.contains("flexible budget eviction"))
        #expect(runtime.contains("incomingWeightsSizeBytes"))
    }

    /// Lock the `.engineShutdown` evict-and-rebuild path. If
    /// `BatchEngine.updateMaxBatchSize(_:)` throws `engineShutdown`
    /// (the cached engine has been torn down between calls), the
    /// adapter MUST evict the dead handle and rebuild — leaving it in
    /// `coalescer.values` would loop forever, contradicting the
    /// "coalescer rebuilds on next first-fetch" doc claim.
    @Test("MLXBatchAdapter handles BatchEngine.updateMaxBatchSize engineShutdown by evicting + rebuilding")
    func mlxBatchAdapterEvictsAndRebuildsOnEngineShutdown() throws {
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")

        #expect(
            adapter.contains("BatchEngineConfigurationError.engineShutdown"),
            "Registry.engine(...) must catch BatchEngineConfigurationError.engineShutdown specifically — a generic catch loses the eviction signal and the dead engine stays in the coalescer forever"
        )
        #expect(
            adapter.contains("evicting and rebuilding at maxBatchSize"),
            "The eviction log line must be present so future debug sessions can confirm the dead-engine path was taken"
        )
        // Eviction goes through the coalescer's dispose variant so the
        // tombstone protects racers from building on a half-shut-down
        // engine. The exact call shape is what locks the discipline.
        #expect(
            adapter.contains("await coalescer.remove(modelName) { engine in"),
            "Eviction must call `coalescer.remove(_:dispose:)` so the tombstone stays alive across the defensive `engine.shutdown()` call (mirrors the shutdownEngine path)"
        )
        // After eviction, recurse so the next first-fetch builds fresh.
        #expect(
            adapter.contains("return await self.engine("),
            "Post-eviction must recurse into engine(...) so the rebuild lands through the coalescer's first-fetch path"
        )
    }

    /// With the default `maxBatchSize == 1`, vmlx can use its solo
    /// TokenIterator-backed fast path. Osaurus must not let a second solo
    /// request run prompt tokenization / `MLXArray.asArray(...)` while that
    /// decode is still active. vmlx emits `.info` before its post-generation
    /// cache store finishes, so Osaurus also must not release the solo lease
    /// at `.info`; otherwise a second request can enter `prepareInput` while
    /// the first one is still materializing safetensors cache tensors on Metal.
    @Test("MLXBatchAdapter gates solo generation and propagates stream cancellation")
    func mlxBatchAdapterGatesSoloGenerationAndCancelsProducer() throws {
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")

        #expect(adapter.contains("actor SoloGenerationGate"))
        #expect(adapter.contains("maxBatchSize == 1"))
        #expect(adapter.contains("acquireSoloLease"))
        #expect(adapter.contains("await soloLease.release()"))
        #expect(
            adapter.contains("lmInput.text.tokenIds")
                && adapter.contains("?? MLXCacheIOLock.withSerializedMLXCacheIO")
                && adapter.contains("lmInput.text.tokens.asArray(Int.self)"),
            "prompt token extraction must use vmlx's CPU tokenIds when available and fall back to the serialized MLX readback only for legacy processors"
        )
        #expect(
            adapter.contains("post-generation disk-cache store")
                && adapter.contains("for await event in upstream")
                && adapter.contains(
                    "if case .info = event {\n                        continuation.yield(event)\n                        continue\n                    }"
                ),
            "adapter must forward terminal info but keep draining vmlx until the upstream stream finishes, so the solo lease covers post-generation cache persistence"
        )
        #expect(
            adapter.contains("continuation.onTermination = { @Sendable _ in")
                && adapter.contains("producerTask.cancel()"),
            "adapter stream termination must cancel the producer so UI Stop reaches vmlx's upstream AsyncStream termination handler"
        )
    }

    /// The terminal `.info` event carries stopReason, token counts, and
    /// `unclosedReasoning`. Dropping it is exactly how a reasoning-only MiniMax
    /// run can finish with a visible Thinking pane but no "thinking did not
    /// close" diagnostic. Cancellation must not be checked before preserving
    /// `.info` / stats sentinels at any Osaurus stream boundary.
    @Test("Generation stream wrappers preserve terminal info before honoring cancellation")
    func generationWrappersPreserveTerminalInfoBeforeCancellation() throws {
        let mapper = try Self.source("Services/ModelRuntime/GenerationEventMapper.swift")
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")
        let runtime = try Self.source("Services/ModelRuntime.swift")
        let chatEngine = try Self.source("Services/Chat/ChatEngine.swift")

        #expect(
            !mapper.contains(
                "for await event in events {\n                    if Task.isCancelled { break }\n                    switch event"
            ),
            "GenerationEventMapper must switch on `.info` before checking Task.isCancelled, otherwise final stats/unclosedReasoning can be lost"
        )
        #expect(
            !adapter.contains(
                "for await event in upstream {\n                    if Task.isCancelled { break }\n                    continuation.yield(event)\n                }"
            ),
            "MLXBatchAdapter must preserve upstream `.info` before honoring cancellation, otherwise vmlx's final cancelled/length/stop event is dropped"
        )
        #expect(
            adapter.contains(
                "if !Task.isCancelled {\n                        continuation.yield(event)\n                    }"
            ),
            "MLXBatchAdapter must keep draining cancelled upstream streams until `.info`, while suppressing only non-terminal deltas after cancellation"
        )
        #expect(
            !adapter.contains(
                "onCancel: {\n                // The upstream stream is bound to a single request inside\n                // the engine; cancelling the consumer task closes it\n                // cooperatively (engine emits a final `.info(.cancelled)`\n                // and finishes the stream).\n                continuation.finish()\n            }"
            ),
            "MLXBatchAdapter's cancellation handler must not immediately finish the wrapper stream while its producer can still drain vmlx's terminal `.info`"
        )
        #expect(
            !runtime.contains(
                "for try await ev in events {\n                    if Task.isCancelled {\n                        continuation.finish()\n                        return\n                    }\n                    switch ev"
            ),
            "ModelRuntime.streamWithTools must encode `.completionInfo` into StreamingStatsHint before honoring cancellation"
        )
        #expect(
            !chatEngine.contains(
                "for try await delta in inner {\n                    // Check for task cancellation to allow early termination\n                    if Task.isCancelled"
            ),
            "ChatEngine stream logging wrapper must pass StreamingStatsHint through before honoring cancellation"
        )
    }

    @Test("ChatEngine honors tool choice none by bypassing local tool dispatch")
    func chatEngineHonorsToolChoiceNoneBypassingLocalToolDispatch() throws {
        let chatEngine = try Self.source("Services/Chat/ChatEngine.swift")

        #expect(chatEngine.contains("private static func allowsLocalToolDispatch"))
        #expect(chatEngine.contains("if case .some(.none) = toolChoice"))
        #expect(
            chatEngine.contains(
                "if Self.allowsLocalToolDispatch(request.tool_choice),\n                let tools = request.tools"
            ),
            "ChatEngine must not route tool_choice none requests through local streamWithTools just because tool schemas are present."
        )
    }

    @Test("ModelRuntime drops structured tool history when no active tools are routed")
    func modelRuntimeDropsStructuredToolHistoryWithoutActiveTools() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")

        #expect(
            runtime.contains("preserveStructuredToolHistory: !tools.isEmpty"),
            "ModelRuntime must not preserve structured assistant/tool history when the request is routed with no active tool schemas."
        )
        #expect(
            runtime.contains("let toolCalls = preserveStructuredToolHistory ? toMLXToolCalls(m.tool_calls) : nil"),
            "Assistant tool_calls must be omitted from the MLX template context when structured tool history is disabled."
        )
        #expect(
            runtime.contains("role: .user,\n                            content: \"Tool result: \\(content)\""),
            "Tool-role results should be converted to ordinary text context when structured tool history is disabled, so follow-up answers can use the result without re-entering tool-call mode."
        )
    }

    /// Background prompt-ranking calls can fall back to the active chat model,
    /// but must not apply a synthetic reasoning mode; runtime/model defaults
    /// remain authoritative unless a caller explicitly supplies model options.
    @Test("Background fallback LLM does not force no-think model options")
    func backgroundFallbackLLMDoesNotForceNoThinkOptions() throws {
        let coreModel = try Self.source("Services/Inference/CoreModelService.swift")
        let greeting = try Self.source("Services/Chat/GenerativeGreetingService.swift")

        #expect(
            coreModel.contains("modelOptions: [String: ModelOptionValue]"),
            "CoreModelService.generate must provide an internal per-call modelOptions path so background callers can choose non-thinking rails without exposing internal option types as public API"
        )
        #expect(
            coreModel.contains("modelOptions: modelOptions"),
            "CoreModelService.generate must thread modelOptions into GenerationParameters before routing to MLX/remote services"
        )
        #expect(
            !greeting.contains("modelOptions: [\"reasoningEffort\": .string(\"no_think\")]"),
            "GenerativeGreetingService must not force no_think for internal greeting calls; model generation_config/runtime defaults remain authoritative"
        )
    }

    @Test("Thinking chip toggles semantic thinking state, not raw inverted booleans")
    func thinkingChipTogglesSemanticThinkingState() throws {
        let floatingInput = try Self.source("Views/Chat/FloatingInputCard.swift")

        #expect(
            floatingInput.contains("ModelProfileRegistry.thinkingEnabled(for: $0, values: activeModelOptions)"),
            "FloatingInputCard.toggleThinking must derive the current semantic thinking state from the registry so inverted options like disableThinking do not flip the wrong way"
        )
        #expect(
            floatingInput.contains("let newVal = thinkingOpt?.inverted == true ? !newEnabled : newEnabled"),
            "FloatingInputCard.toggleThinking must write the profile-specific stored value from the semantic enabled state"
        )
        #expect(
            !floatingInput.contains("let current = activeModelOptions[id]?.boolValue ?? false"),
            "Thinking chip must not toggle the raw stored bool directly; that reintroduces first-click explicit no-thinking for inverted profiles"
        )
    }

    @Test("MLXBatchAdapter image preprocessing preserves media, reasoning, and tool metadata")
    func mlxBatchAdapterPreprocessingPreservesMediaReasoningAndToolMetadata() throws {
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")
        guard let rebuildRange = adapter.range(of: "return MLXLMCommon.Chat.Message(") else {
            Issue.record("Could not find Chat.Message rebuild in MLXBatchAdapter.preprocessImages")
            return
        }
        let rebuild = adapter[rebuildRange.lowerBound...]
            .prefix(while: { $0 != ")" })

        #expect(rebuild.contains("images: processedImages"))
        #expect(rebuild.contains("videos: message.videos"))
        #expect(
            rebuild.contains("audios: message.audios"),
            "preprocessImages must not drop audio inputs before vmlx omni/audio tokenization"
        )
        #expect(
            rebuild.contains("reasoningContent: message.reasoningContent"),
            "preprocessImages must not drop assistant reasoning history before vmlx Jinja templates render message.reasoning_content"
        )
        #expect(rebuild.contains("toolCalls: message.toolCalls"))
        #expect(rebuild.contains("toolCallId: message.toolCallId"))
    }

    @Test("HTTP streams preserve stats hints before generic sentinel filters")
    func httpStreamsPreserveStatsHintsBeforeGenericSentinelFilters() throws {
        let handler = try Self.source("Networking/HTTPHandler.swift")

        let segments = handler.components(separatedBy: "StreamingToolHint.isSentinel(delta)")

        #expect(
            segments.count == 7,
            "HTTPHandler should have six generic StreamingToolHint sentinel filters; update this guard when adding another HTTP stream writer"
        )

        for segment in segments.dropLast() {
            #expect(
                segment.contains("StreamingStatsHint.decode(delta)"),
                "Each HTTP stream writer must decode StreamingStatsHint before the generic U+FFFE sentinel filter, otherwise API usage stats and unclosedReasoning are dropped"
            )
        }
    }

    @Test("Agent run endpoint does not stream internal tool sentinels to clients")
    func agentRunEndpointDoesNotStreamInternalToolSentinels() throws {
        let handler = try Self.source("Networking/HTTPHandler.swift")
        guard let start = handler.range(of: "private func handleAgentRunEndpoint("),
            let end = handler.range(
                of: "// MARK: - Dispatch & Task Endpoints",
                range: start.lowerBound ..< handler.endIndex
            )
        else {
            Issue.record("Could not locate handleAgentRunEndpoint in HTTPHandler.swift")
            return
        }

        let agentRun = handler[start.lowerBound ..< end.lowerBound]
        #expect(agentRun.contains("AgentToolLoop.runBatchInParallel"))
        #expect(
            !agentRun.contains("StreamingToolHint.encode(")
                && !agentRun.contains("StreamingToolHint.encodeArgs")
                && !agentRun.contains("StreamingToolHint.encodeDone"),
            "/agents/{id}/run should execute tools server-side and stream only final assistant text, not internal U+FFFE tool sentinels."
        )
        #expect(agentRun.contains("assistantToolCalls.append"))
        #expect(agentRun.contains("ChatMessage(role: \"tool\""))
    }

    @Test("Agent finalization keeps tool_choice stable post-tool (no prefix-busting downgrade)")
    func agentFinalizationKeepsToolChoiceStablePostTool() throws {
        let handler = try Self.source("Networking/HTTPHandler.swift")
        let chatPolicy = try Self.source("Services/Chat/ChatToolChoicePolicy.swift")
        let agentRun = try Self.functionBody("private func handleAgentRunEndpoint(", in: handler)
        let chatView = try Self.source("Views/Chat/ChatView.swift")

        // The obsolete Gemma-QAT post-tool downgrade (flip auto->none) is gone.
        // It stripped the rendered `<tools>` block from the system prefix on the
        // finalization step, shrinking the prompt below the calling step's
        // prefix and forcing a full KV re-prefill. The upstream prose corruption
        // that motivated it is fixed, so tools stay visible and the prefix stays
        // byte-stable across iterations.
        #expect(
            !chatPolicy.contains("finalizingPostToolChoice"),
            "Post-tool tool_choice downgrade must not be reintroduced; it busts the KV prefix."
        )
        #expect(
            !chatPolicy.contains("gemma-4"),
            "ChatToolChoicePolicy must not special-case Gemma post-tool tool_choice."
        )
        #expect(
            !chatPolicy.contains("ToolChoiceOption.none"),
            "Post-tool finalization must not downgrade tool_choice to .none."
        )

        // Both agent loops reuse the resolved/requested tool_choice every
        // iteration (no post-tool downgrade), so the post-tool prompt extends the
        // calling prompt's KV prefix instead of re-prefilling.
        #expect(!agentRun.contains("finalizingPostToolChoice"))
        #expect(agentRun.contains("tool_choice: resolvedToolChoice"))
        #expect(!chatView.contains("finalizingPostToolChoice"))
        #expect(chatView.contains("let requestedToolChoice = ChatToolChoicePolicy.resolve("))
        #expect(chatView.contains("tool_choice: requestedToolChoice"))
    }

    @Test("OpenAI chat completions endpoint does not inject agent context")
    func openAIChatCompletionsEndpointDoesNotInjectAgentContext() throws {
        let handler = try Self.source("Networking/HTTPHandler.swift")
        guard let start = handler.range(of: "private func handleChatCompletions("),
            let end = handler.range(
                of: "private func handleChatNDJSON(",
                range: start.lowerBound ..< handler.endIndex
            )
        else {
            Issue.record("Could not locate handleChatCompletions in HTTPHandler.swift")
            return
        }

        let chatCompletions = handler[start.lowerBound ..< end.lowerBound]
        #expect(chatCompletions.contains("let enrichedReq = req"))
        #expect(chatCompletions.contains("http_context_passthrough_done"))
        #expect(chatCompletions.contains("X-Osaurus-Agent-Id"))
        #expect(chatCompletions.contains("agentId: resolvedAgentUUID"))
        #expect(!chatCompletions.contains("enrichWithAgentContext("))
        #expect(!chatCompletions.contains("composeChatContext("))
        #expect(!chatCompletions.contains("injectMemoryPrefix("))
        #expect(!chatCompletions.contains("mergeAgentContextTools("))
    }

    @Test("Open Responses endpoint has v1 alias and does not inject agent context")
    func openResponsesEndpointHasV1AliasAndDoesNotInjectAgentContext() throws {
        let handler = try Self.source("Networking/HTTPHandler.swift")
        let serverView = try Self.source("Views/Settings/ServerView.swift")

        #expect(handler.contains(#"path == "/responses" || path == "/v1/responses""#))
        #expect(serverView.contains(#"path: "/v1/responses""#))

        guard let start = handler.range(of: "private func handleOpenResponses("),
            let end = handler.range(
                of: "private func handleOpenResponsesStreaming(",
                range: start.lowerBound ..< handler.endIndex
            )
        else {
            Issue.record("Could not locate handleOpenResponses in HTTPHandler.swift")
            return
        }

        let responses = handler[start.lowerBound ..< end.lowerBound]
        #expect(responses.contains("toChatCompletionRequest()"))
        #expect(!responses.contains("enrichWithAgentContext("))
        #expect(!responses.contains("composeChatContext("))
        #expect(!responses.contains("injectMemoryPrefix("))
        #expect(!responses.contains("mergeAgentContextTools("))
    }

    @Test("server streaming endpoints honor runtime stream interval")
    func serverStreamingEndpointsHonorRuntimeStreamInterval() throws {
        let handler = try Self.source("Networking/HTTPHandler.swift")
        let helper = try Self.source("Networking/HTTPLoopHelpers.swift")

        #expect(helper.contains("struct StreamDeltaCoalescer"))
        #expect(helper.contains("TokenEstimator.estimate(delta)"))

        let bridge = "ServerRuntimeSettingsStore.snapshot().generation.streamInterval"
        #expect(
            handler.components(separatedBy: bridge).count == 7,
            "Expected six streaming server paths to bridge generation.streamInterval through StreamDeltaCoalescer"
        )
        #expect(handler.contains("writerBound.value.writeContent(\n                                    chunk"))
        #expect(handler.contains("writerBound.value.writeTextDelta(chunk"))
    }

    @Test("HTTP channel close cancels per-request streaming tasks")
    func httpChannelCloseCancelsPerRequestStreamingTasks() throws {
        let handler = try Self.source("Networking/HTTPHandler.swift")
        let helper = try Self.source("Networking/HTTPLoopHelpers.swift")
        let runtime = try Self.source("Services/ModelRuntime.swift")
        let chatEngine = try Self.source("Services/Chat/ChatEngine.swift")

        #expect(helper.contains("final class HTTPRequestTaskRegistry"))
        #expect(helper.contains("func cancelAll()"))
        #expect(helper.contains("task.cancel()"))
        #expect(handler.contains("private let requestTasks = HTTPRequestTaskRegistry()"))
        #expect(handler.contains("requestTasks.cancelAll()"))
        #expect(handler.contains("private func runRequestTask("))
        #expect(handler.contains("requestTasks.insert(id: id, task: task)"))
        #expect(handler.contains("defer { requestTasks.remove(id: id) }"))
        #expect(handler.contains("private final class ChannelCloseFutureBox: @unchecked Sendable"))
        #expect(handler.contains("private let channelCloseFuture = ChannelCloseFutureBox()"))
        #expect(handler.contains("channelCloseFuture.set(context.channel.closeFuture)"))
        #expect(handler.contains("channelCloseFuture.snapshot()?.whenComplete { _ in\n            task.cancel()"))
        #expect(handler.contains("func userInboundEventTriggered(context: ChannelHandlerContext, event: Any)"))
        #expect(handler.contains("if case ChannelEvent.inputClosed = event"))
        #expect(handler.contains("context.fireUserInboundEventTriggered(event)"))
        #expect(!handler.contains("intervalNanoseconds: 250_000_000"))
        #expect(handler.contains("let keepaliveTask = Self.startSSEKeepalive("))
        #expect(handler.contains("intervalNanoseconds: UInt64 = 15_000_000_000"))
        #expect(handler.contains("promise.futureResult.whenFailure"))
        #expect(handler.contains("ctx.value.close(promise: nil)"))
        #expect(handler.contains("ctx.value.read()"))
        #expect(handler.contains("let disconnected = SendableBool(false)"))
        #expect(handler.contains("disconnected: disconnected"))
        #expect(handler.contains("disconnected?.value = true"))
        #expect(handler.contains("if disconnected.value { throw CancellationError() }"))
        #expect(handler.contains("let channelClosed = SendableBool(false)"))
        #expect(handler.contains("let wasResidentBeforeStream = await ModelRuntime.shared.isResident(name: model)"))
        #expect(handler.contains("let responseFinished = SendableBool(false)"))
        #expect(handler.contains("let wasResidentBeforeComplete = SendableBool(false)"))
        #expect(handler.contains("await ModelRuntime.shared.cancelGeneration(name: model)"))
        #expect(handler.contains("wasResidentBeforeComplete.value = await ModelRuntime.shared.isResident(name: model)"))
        #expect(
            handler.contains(
                "try Task.checkCancellation()\n                    var resp = try await chatEngine.completeChat(request: enrichedReq)"
            )
        )
        #expect(
            handler.contains(
                "var resp = try await chatEngine.completeChat(request: enrichedReq)\n                    try Task.checkCancellation()"
            )
        )
        #expect(handler.contains("var emittedSemanticDelta = false"))
        #expect(handler.contains("func markSemanticDeltaIfConnected()"))
        #expect(handler.contains("if self._isChannelActive.value && !disconnected.value && !channelClosed.value"))
        #expect(handler.contains("func markSemanticDeltaIfChannelActive()"))
        #expect(handler.contains("if self._isChannelActive.value {\n                    emittedSemanticDelta = true"))
        #expect(handler.contains("!wasResidentBeforeStream && !emittedSemanticDelta"))
        #expect(handler.contains("!self._isChannelActive.value || Task.isCancelled"))
        #expect(handler.contains("await ModelRuntime.shared.unload(name: model)"))
        let completionsStart = try #require(handler.range(of: "private func handleChatCompletions("))
        let completionsEnd = try #require(
            handler.range(
                of: "private func handleChatNDJSON(",
                range: completionsStart.upperBound ..< handler.endIndex
            )
        )
        let chatCompletions = String(handler[completionsStart.lowerBound ..< completionsEnd.lowerBound])
        #expect(chatCompletions.contains("func markSemanticDeltaIfConnected()"))
        #expect(chatCompletions.contains("markSemanticDeltaIfConnected()"))
        #expect(chatCompletions.contains("!disconnected.value && !channelClosed.value"))
        let ndjsonStart = try #require(handler.range(of: "private func handleChatNDJSON("))
        let ndjsonEnd = try #require(
            handler.range(
                of: "private func handleOllamaChatNonStreaming(",
                range: ndjsonStart.upperBound ..< handler.endIndex
            )
        )
        let ndjsonStreaming = String(handler[ndjsonStart.lowerBound ..< ndjsonEnd.lowerBound])
        #expect(
            ndjsonStreaming.contains(
                "let wasResidentBeforeStream = await ModelRuntime.shared.isResident(name: req.model)"
            )
        )
        #expect(ndjsonStreaming.contains("func markSemanticDeltaIfChannelActive()"))
        #expect(ndjsonStreaming.contains("await ModelRuntime.shared.unload(name: req.model)"))
        #expect(
            ndjsonStreaming.contains(
                "try Task.checkCancellation()\n                    if disconnected.value { throw CancellationError() }\n                    // Ollama-style NDJSON"
            )
        )
        let anthropicStart = try #require(handler.range(of: "private func handleAnthropicMessagesStreaming("))
        let anthropicEnd = try #require(
            handler.range(
                of: "private func handleAnthropicMessagesNonStreaming(",
                range: anthropicStart.upperBound ..< handler.endIndex
            )
        )
        let anthropicStreaming = String(handler[anthropicStart.lowerBound ..< anthropicEnd.lowerBound])
        #expect(
            anthropicStreaming.contains(
                "let wasResidentBeforeStream = await ModelRuntime.shared.isResident(name: model)"
            )
        )
        #expect(anthropicStreaming.contains("func markSemanticDeltaIfChannelActive()"))
        #expect(anthropicStreaming.contains("markSemanticDeltaIfChannelActive()"))
        #expect(anthropicStreaming.contains("await ModelRuntime.shared.unload(name: model)"))
        #expect(
            anthropicStreaming.contains(
                "try Task.checkCancellation()\n                    if disconnected.value { throw CancellationError() }\n                    // Reasoning sentinel"
            )
        )
        let responsesStart = try #require(handler.range(of: "private func handleOpenResponsesStreaming("))
        let responsesEnd = try #require(
            handler.range(
                of: "private static func openResponsesNonStreamingBody(",
                range: responsesStart.upperBound ..< handler.endIndex
            )
        )
        let responsesStreaming = String(handler[responsesStart.lowerBound ..< responsesEnd.lowerBound])
        #expect(
            responsesStreaming.contains(
                "let wasResidentBeforeStream = await ModelRuntime.shared.isResident(name: model)"
            )
        )
        #expect(responsesStreaming.contains("var emittedSemanticDelta = false"))
        #expect(responsesStreaming.contains("func markSemanticDeltaIfChannelActive()"))
        #expect(responsesStreaming.contains("!wasResidentBeforeStream && !emittedSemanticDelta"))
        #expect(responsesStreaming.contains("await ModelRuntime.shared.unload(name: model)"))
        #expect(
            responsesStreaming.contains(
                "try Task.checkCancellation()\n                    if disconnected.value { throw CancellationError() }\n                    // Reasoning sentinel"
            )
        )
        let errorStart = try #require(handler.range(of: "func errorCaught"))
        let errorEnd = try #require(
            handler.range(of: "    // MARK: - CORS", range: errorStart.upperBound ..< handler.endIndex)
        )
        let errorCaught = String(handler[errorStart.lowerBound ..< errorEnd.lowerBound])
        #expect(errorCaught.contains("requestTasks.cancelAll()"))
        #expect(runtime.contains("func cancelGeneration(name: String) async"))
        #expect(runtime.contains("await MLXBatchAdapter.Registry.shared.shutdownEngine(for: name)"))
        #expect(
            chatEngine.contains("for try await delta in stream {\n                        try Task.checkCancellation()")
        )
        #expect(chatEngine.contains("for try await delta in stream {\n                try Task.checkCancellation()"))

        #expect(
            !handler.contains("\n        Task(priority: .userInitiated)"),
            "Per-request HTTP work must go through runRequestTask so channelInactive can cancel model loads/generation"
        )
        #expect(handler.components(separatedBy: "runRequestTask(priority: .userInitiated)").count >= 8)
        #expect(
            handler.contains(
                "try Task.checkCancellation()\n                    let stream = try await chatEngine.streamChat(request: enrichedReq)"
            )
        )
        #expect(
            handler.contains(
                "try Task.checkCancellation()\n                let stream = try await chatEngine.streamChat(request: req)"
            )
        )
        #expect(handler.contains("let stream = try await chatEngine.streamChat(request: req)"))
        #expect(handler.contains("let stream = try await self.chatEngine.streamChat(request: chatRequest)"))
        #expect(handler.contains("let stream = try await chatEngine.streamChat(request: internalReq)"))
    }

    /// Lock the removal of the `activeGenerationTask?.value` gate at
    /// the entry of `generateEventStream`. The gate was serializing
    /// every same-model overlapping request before vmlx's `BatchEngine`
    /// could see it, defeating continuous batching. The field's own
    /// doc (lines 82-87) says "lease drives correctness — many can be
    /// active simultaneously"; if a future refactor reintroduces the
    /// gate, this test breaks first and forces the discussion.
    @Test("ModelRuntime.generateEventStream does not serialize on activeGenerationTask")
    func generateEventStreamDoesNotSerializeOnActiveGenerationTask() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")

        // The gate would look like `_ = await activeGenerationTask?.value`
        // anywhere outside `cancelActiveGeneration()` (which legitimately
        // awaits the task on shutdown). The pattern here is narrow: any
        // `await activeGenerationTask?.value` on a line whose enclosing
        // function is NOT `cancelActiveGeneration` is the gate we removed.
        // We assert the public-side gate is gone by spot-checking the
        // generation entry point's neighborhood and the explanatory
        // comment that locks the rationale.
        #expect(
            runtime.contains("// No serialization gate against `activeGenerationTask` here:"),
            "ModelRuntime.generateEventStream must keep the explanatory comment that documents why the gate was removed; if the comment goes away, the policy is undocumented and the next refactor may silently reintroduce serialization"
        )
        #expect(
            runtime.contains("ModelLease` is the authoritative"),
            "Comment must call out that the lease is the authoritative concurrency signal"
        )
        // The cancelActiveGeneration helper still legitimately awaits
        // the task; that's fine and remains in the file.
        #expect(
            runtime.contains("private func cancelActiveGeneration(for modelName: String? = nil) async {"),
            "cancelActiveGeneration() must still exist for shutdown / clearAll cancellation paths"
        )
        #expect(
            runtime.contains("modelName == nil || record.modelName == modelName"),
            "cancelActiveGeneration(for:) must scope cancellation to the requested model (nil = cancel all)"
        )
        #expect(
            runtime.contains("await cancelActiveGeneration(for: name)"),
            "ModelRuntime.unload(name:) must scope defensive cancellation to the model being unloaded"
        )
    }

    /// Lock the cold-load drain discipline. Swift task cancellation is
    /// cooperative; a cancelled `loadModelContainer` can still be inside MLX
    /// weight materialization. Starting a replacement load before the old task
    /// drains leaves two independent MLX load/eval paths racing on Metal.
    @Test("ModelRuntime drains superseded cold loads before starting replacements")
    func modelRuntimeDrainsSupersededColdLoads() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")

        #expect(runtime.contains("private struct LoadingTaskRecord"))
        #expect(runtime.contains("supersededLoadingTaskIDs"))
        #expect(runtime.contains("private func cancelAndDrainLoadingTasks"))
        #expect(runtime.contains("record.task.cancel()"))
        #expect(runtime.contains("try? await record.task.value"))
        #expect(runtime.contains("holder.container.disableCaching()"))
        #expect(runtime.contains("loadContainer: strict drain of in-flight load"))
        #expect(runtime.contains("return try await finishLoadedContainer"))
        #expect(
            !runtime.contains("loadingTasks[other]?.cancel()"),
            "Strict single-model replacement must not fire-and-forget cancel an in-flight model load"
        )
    }

    @Test("app termination stops sessions before draining model runtime")
    func appTerminationStopsSessionsBeforeDrainingModelRuntime() throws {
        let appDelegate = try Self.source("AppDelegate.swift")
        let start = try #require(appDelegate.range(of: "public func applicationShouldTerminate"))
        let end = try #require(
            appDelegate.range(
                of: "public func applicationWillTerminate",
                range: start.upperBound ..< appDelegate.endIndex
            )
        )
        let body = String(appDelegate[start.lowerBound ..< end.lowerBound])

        let stopSessions = try #require(body.range(of: "ChatWindowManager.shared.stopAllSessions()"))
        let clearRuntime = try #require(body.range(of: "await ModelRuntime.shared.clearAll(quit: true)"))
        let replyTerminate = try #require(
            body.range(of: "NSApp.reply(toApplicationShouldTerminate: true)")
        )

        #expect(stopSessions.lowerBound < clearRuntime.lowerBound)
        #expect(clearRuntime.lowerBound < replyTerminate.lowerBound)
        #expect(body.contains("return .terminateLater"))

        // Hang audit: the teardown must be bounded (every step wrapped in a
        // deadline) and must always reply via a watchdog-guarded one-shot so
        // a stuck step can never strand the app in "quitting".
        #expect(
            body.contains("runWithDeadline"),
            "applicationShouldTerminate steps must be bounded by runWithDeadline so a stuck await can't hang quit"
        )
        #expect(
            body.contains("replyToTerminationOnce()"),
            "termination reply must funnel through the watchdog-guarded one-shot"
        )
        #expect(
            body.contains("Quit watchdog fired"),
            "a global quit watchdog must force the termination reply if the teardown chain wedges"
        )

        // Reentrancy guard: a second/racing quit must early-return without
        // spawning a duplicate teardown chain + watchdog.
        #expect(
            body.contains("if isTerminating"),
            "applicationShouldTerminate must guard against re-entry with isTerminating"
        )
        #expect(
            body.contains("isTerminating = true"),
            "applicationShouldTerminate must latch isTerminating on first entry"
        )
        // The only `hasRepliedToTermination = false` allowed is the stored
        // property's default initializer; resetting it on entry would defeat
        // the reentrancy guard, so there must be exactly one occurrence.
        #expect(
            body.components(separatedBy: "hasRepliedToTermination = false").count - 1 == 1,
            "the reply flag must not be reset on entry — that would defeat the reentrancy guard"
        )

        // Reordering: the must-not-orphan steps (cancel generations, child
        // process / NIO / VM teardown) must run BEFORE the abandonable
        // MLX/memory tail, so a watchdog firing only ever cuts GPU/memory.
        let cancelGen = try #require(body.range(of: "await ModelRuntime.shared.cancelAllGenerations()"))
        let liveExec = try #require(body.range(of: "await LiveExecRegistry.shared.terminateAll()"))
        let ensureShutdown = try #require(body.range(of: "await self.serverController.ensureShutdown()"))
        let flush = try #require(body.range(of: "await MemoryService.shared.flushAllPending"))

        #expect(
            cancelGen.lowerBound < ensureShutdown.lowerBound,
            "generations must be cancelled (ending SSE) before NIO shutdown so the server can drain"
        )
        #expect(
            liveExec.lowerBound < flush.lowerBound,
            "orphan-prone child processes must be killed before the abandonable memory/MLX tail"
        )
        #expect(
            ensureShutdown.lowerBound < clearRuntime.lowerBound,
            "network/VM teardown must run before the abandonable MLX clearAll tail"
        )
    }

    @Test("NIO server stop reports completion so the group isn't dropped mid-shutdown")
    func nioServerStopReportsCompletion() throws {
        let server = try Self.source("Networking/OsaurusServer.swift")
        // `stop` must return whether the EventLoopGroup actually shut down.
        #expect(
            server.contains("func stop(gracefully: Bool = true) async -> Bool"),
            "OsaurusServer.stop must return whether shutdown completed"
        )

        let controller = try Self.source("Networking/ServerController.swift")
        let start = try #require(controller.range(of: "func ensureShutdown() async"))
        let end = try #require(
            controller.range(of: "init()", range: start.upperBound ..< controller.endIndex)
        )
        let body = String(controller[start.lowerBound ..< end.lowerBound])

        // On timeout the actor (and its EventLoopGroup) must stay rooted — only
        // drop it when shutdown actually completed (issue #860).
        #expect(
            body.contains("let completed = await server.stop(gracefully: false)"),
            "ensureShutdown must capture whether the bounded NIO shutdown completed"
        )
        #expect(
            body.contains("if completed {") && body.contains("serverActor = nil"),
            "ensureShutdown must only release serverActor when the group fully shut down"
        )
        #expect(
            body.contains("BonjourAdvertiser.shared.stopAdvertising()"),
            "ensureShutdown must also stop mDNS advertising on the quit path"
        )
    }

    @Test("live proof keychain-disabled mode keeps app startup off user Keychain")
    func liveProofKeychainDisabledModeKeepsStartupOffUserKeychain() throws {
        let paths = try Self.source("Utils/OsaurusPaths.swift")
        let storage = try Self.source("Identity/StorageKeyManager.swift")
        let appDelegate = try Self.source("AppDelegate.swift")
        let keychainHelper = try Self.source("Services/Keychain/KeychainQueryHelpers.swift")
        let agentSecrets = try Self.source("Services/Keychain/AgentSecretsKeychain.swift")
        let toolSecrets = try Self.source("Services/Keychain/ToolSecretsKeychain.swift")
        let remoteProvider = try Self.source("Services/Provider/RemoteProviderKeychain.swift")
        let mcpProvider = try Self.source("Services/MCP/MCPProviderKeychain.swift")

        #expect(paths.contains("OSAURUS_TEST_ROOT"))
        #expect(storage.contains("OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS"))
        #expect(storage.contains("generateInMemoryKey()"))
        #expect(storage.contains("if Self.disablesKeychainForProcess"))
        #expect(appDelegate.contains("private var keychainDisabledTestMode"))
        #expect(appDelegate.contains("private var keychainDisabledUIPresentationMode"))
        #expect(appDelegate.contains("OSAURUS_KEYCHAIN_FREE_SHOW_UI"))
        #expect(appDelegate.contains("Keychain disabled by OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS=1"))
        #expect(appDelegate.contains("if keychainDisabledTestMode {"))
        #expect(appDelegate.contains("LaunchGuard.markStartupComplete()"))
        #expect(
            appDelegate.contains(
                "if !keychainDisabledTestMode {\n                await MCPProviderManager.shared.connectEnabledProviders()"
            )
        )
        #expect(
            appDelegate.contains(
                "if !keychainDisabledTestMode && !LaunchGuard.shouldSkip(.sandbox) {\n            SandboxToolRegistrar.shared.start()"
            )
        )
        #expect(appDelegate.contains("Headless live-proof launches only need the local HTTP server"))
        #expect(appDelegate.contains("keychainDisabledTestMode && !keychainDisabledUIPresentationMode"))
        #expect(keychainHelper.contains("disablesKeychainForProcess"))
        #expect(agentSecrets.contains("if KeychainQueryHelpers.disablesKeychainForProcess { return nil }"))
        #expect(toolSecrets.contains("if KeychainQueryHelpers.disablesKeychainForProcess { return nil }"))
        #expect(remoteProvider.contains("if KeychainQueryHelpers.disablesKeychainForProcess { return nil }"))
        #expect(mcpProvider.contains("if KeychainQueryHelpers.disablesKeychainForProcess { return nil }"))
    }

    @Test("ModelRuntime uses typed vmlx load configuration")
    func modelRuntimeUsesTypedVMLXLoadConfiguration() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")

        #expect(runtime.contains("loadConfiguration: mtpPlan.loadConfiguration"))
        #expect(runtime.contains("resolvedLoadConfiguration("))
        #expect(runtime.contains("resolveMemorySafetyLoadPlan("))
        #expect(runtime.contains("settings.resolvedMemorySafetyPlan("))
        #expect(runtime.contains("baseLoadConfiguration: loadConfiguration"))
        #expect(runtime.contains("request: nil"))
        #expect(runtime.contains("memorySafetySummary: memorySafetyPlan.displaySummary"))
        #expect(runtime.contains("base: .osaurusProduction"))
        #expect(runtime.contains("baseLoadConfiguration: .osaurusProduction"))
        #expect(runtime.contains("loadConfiguration: memorySafetyPlan.loadConfiguration"))
        #expect(!runtime.contains("base: .default"))
        #expect(!runtime.contains("loadConfiguration: .default"))
        #expect(!runtime.contains("throw LoadRefusedError("))
        #expect(
            !runtime.contains(
                "loadModelContainer(\n                from: localURL,\n                using: tokenizerLoader\n            )"
            ),
            "ModelRuntime must not use the plain local-directory load overload; it bypasses vmlx LoadConfiguration.osaurusProduction, including load-time memory caps, mmap safetensors, and routed MLXPress auto policy"
        )
    }

    @Test("ModelRuntime keeps weight-size directory scans out of the default load path")
    func modelRuntimeWeightSizePreflightIsManualMultiModelOnly() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")
        let start = try #require(runtime.range(of: "private static func computeWeightsSizeBytes"))
        let end =
            runtime.range(of: "private static func findLocalDirectory", range: start.upperBound ..< runtime.endIndex)?
            .lowerBound
            ?? runtime.endIndex
        let body = String(runtime[start.lowerBound ..< end])

        #expect(body.contains("contentsOfDirectory("))
        let knownMiMoN2Size = try #require(body.range(of: "knownMiMoOrN2JANGTQWeightsSizeBytes"))
        let indexRead = try #require(body.range(of: "Data(contentsOf: indexURL)"))
        #expect(
            knownMiMoN2Size.lowerBound < indexRead.lowerBound,
            "Known MiMo/N2 JANGTQ app preflight must not open external index JSON before it can use exact bundle-size metadata."
        )
        let totalSize = try #require(body.range(of: "metadata[\"total_size\"]"))
        let shardLoop = try #require(body.range(of: "for shardCount in 2 ... 256"))
        #expect(
            totalSize.lowerBound < shardLoop.lowerBound,
            "Sharded safetensors bundles must use metadata.total_size before probing every shard file on external volumes."
        )
        #expect(
            !body.contains("enumerator("),
            "Weight-size preflight must not recursively walk huge model bundles or symlinked cache folders on the request path."
        )
        #expect(
            body.contains("model-%05d-of-%05d.safetensors")
                && body.contains("fileURL.pathExtension.lowercased() == \"safetensors\""),
            "Weight-size preflight must count known numbered shards and fall back to a shallow safetensors sum so unknown layouts cannot report 0 bytes."
        )

        let loadStart = try #require(runtime.range(of: "func loadContainer(id: String, name: String)"))
        let loadEnd = try #require(
            runtime.range(of: "let loadID = allocateLoadingTaskID()", range: loadStart.upperBound ..< runtime.endIndex)
        )
        let loadPreflight = String(runtime[loadStart.lowerBound ..< loadEnd.lowerBound])
        // `computeWeightsSizeBytes` is a shallow (non-recursive) directory
        // listing — the `enumerator(` guard above keeps it off the deep-walk
        // path. It is now computed for EVERY policy (not just manualMultiModel)
        // because the pre-load RAM-feasibility gate and the in-flight-load
        // reservation both need the incoming bundle's footprint up front.
        #expect(loadPreflight.contains("if policy == .manualMultiModel"))
        #expect(
            loadPreflight.contains("let weightsBytes = Self.computeWeightsSizeBytes(at: localURL, modelName: name)")
        )
        #expect(
            loadPreflight.contains("let loadFootprintBytes = Self.effectiveLoadFootprintBytes("),
            "Routed mmap/JANGTQ loads must feed the RAM gate with vMLX's effective hot working set, not the whole safetensors shard total."
        )
        // Feasibility gate + concurrent-load reservation must run before the
        // load task is allocated, so a cold load can't bypass RAM accounting.
        #expect(
            loadPreflight.contains("inflightLoadWeights[name] = loadFootprintBytes"),
            "Cold loads must reserve their footprint before the feasibility gate so a parallel load of another model can't double-book unified memory."
        )
        #expect(
            runtime.contains("private var coldLoadActive = false")
                && runtime.contains("private func acquireColdLoadSlot() async")
                && runtime.contains("private func releaseColdLoadSlot()")
                && loadPreflight.contains("await acquireColdLoadSlot()")
                && loadPreflight.contains("defer { releaseColdLoadSlot() }"),
            "Cold loads must serialize before vmlx model materialization; RAM accounting alone does not prevent concurrent MLX/Metal command-buffer setup."
        )
        #expect(
            loadPreflight.contains("checkRAMFeasibility("),
            "All policies must record the pre-load RAM feasibility assessment before vmlx starts loading."
        )
        #expect(
            runtime.contains("ServerRuntimeSettingsStore.modelLoadRAMThresholds()")
                && !runtime.contains("ramHardThreshold = 0.90")
                && !runtime.contains("ramSoftThreshold = 0.70")
                && !runtime.contains("* 0.70"),
            "RAM load thresholds must come from persisted server configuration, not hidden hardcoded ModelRuntime constants."
        )
        #expect(
            runtime.contains("availableMemoryBytes()")
                && runtime.contains("requiredAvailable > available")
                && runtime.contains("incomingLoadFootprintBytes")
                && runtime.contains("availableMemoryBytes: available"),
            "The load assessment must track available memory and expose it through health/logs without using it as a hard RAM block."
        )
        let assessmentBody = try Self.functionBody(
            "private func checkRAMFeasibility",
            in: runtime
        )
        // RAM pressure must not refuse a user-requested load: unified memory
        // makes both free pages and projected hard-threshold estimates
        // advisory for mmap-backed JANG/JANGTQ/quantized loads.
        #expect(
            assessmentBody.contains("let lowAvailable = available > 0 && requiredAvailable > available")
                && assessmentBody.contains("projected > hardLimit || projected > softLimit || lowAvailable")
                && !assessmentBody.contains("throw LoadRefusedError(")
                && !assessmentBody.contains("verdict = .refused"),
            "RAM pressure must warn as .tight, not throw or mark a hard refusal before vMLX attempts the load."
        )

        let health = try Self.source("Networking/HTTPHandler.swift")
        #expect(health.contains("\"available_memory_bytes\": f.availableMemoryBytes"))
        #expect(health.contains("\"required_available_bytes\": f.requiredAvailableBytes"))
        #expect(health.contains("\"incoming_load_footprint_bytes\": f.incomingLoadFootprintBytes"))
    }

    @Test("MiMo and N2 text runtime metadata avoids VLM bundle reads")
    func mimoAndN2TextRuntimeMetadataAvoidsVLMBundleReads() throws {
        let model = try Self.source("Models/Configuration/MLXModel.swift")
        let vlm = try Self.source("Models/Configuration/VLMDetection.swift")
        let runtime = try Self.source("Services/ModelRuntime.swift")

        let isVLMStart = try #require(model.range(of: "var isVLM: Bool"))
        let isDownloaded = try #require(
            model.range(
                of: "if isDownloaded { return VLMDetection.isVLM(at: localDirectory) }",
                range: isVLMStart.lowerBound ..< model.endIndex
            )
        )
        let modelFastPath = try #require(
            model.range(
                of: "ModelFamilyNames.isMiMoOrN2JANGRuntimeFamily",
                range: isVLMStart.lowerBound ..< isDownloaded.lowerBound
            )
        )
        #expect(modelFastPath.lowerBound < isDownloaded.lowerBound)

        let idStart = try #require(vlm.range(of: "static func isVLM(modelId: String)"))
        let dirLookup = try #require(
            vlm.range(
                of: "findLocalModelDirectory(forModelId: modelId)",
                range: idStart.lowerBound ..< vlm.endIndex
            )
        )
        let vlmFastPath = try #require(
            vlm.range(
                of: "ModelFamilyNames.isMiMoOrN2JANGRuntimeFamily(modelId)",
                range: idStart.lowerBound ..< dirLookup.lowerBound
            )
        )
        #expect(vlmFastPath.lowerBound < dirLookup.lowerBound)

        let compressionStart = try #require(runtime.range(of: "private static func isRoutedJANGTQCompressionLoad"))
        let jsonRead = try #require(
            runtime.range(of: "Self.readJSONObject", range: compressionStart.lowerBound ..< runtime.endIndex)
        )
        let compressionFastPath = try #require(
            runtime.range(
                of: "ModelFamilyNames.isMiMoOrN2JANGRuntimeFamily(modelName)",
                range: compressionStart.lowerBound ..< jsonRead.lowerBound
            )
        )
        #expect(compressionFastPath.lowerBound < jsonRead.lowerBound)

        let mtpStart = try #require(runtime.range(of: "private nonisolated static func resolveNativeMTPLaunchPlan"))
        let mtpJSONRead = try #require(
            runtime.range(of: "Data(contentsOf:", range: mtpStart.lowerBound ..< runtime.endIndex)
        )
        let mtpFastPath = try #require(
            runtime.range(
                of: "ModelFamilyNames.isMiMoOrN2JANGRuntimeFamily(modelName)",
                range: mtpStart.lowerBound ..< mtpJSONRead.lowerBound
            )
        )
        #expect(mtpFastPath.lowerBound < mtpJSONRead.lowerBound)
    }

    @Test("MTP bundles auto-resolve vmlx tuning into load and generation")
    func mtpBundlesAutoResolveVMLXTuningIntoLoadAndGeneration() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")

        #expect(runtime.contains("MTPBundleInspector.inspect("))
        #expect(runtime.contains("let serverSettings = ServerRuntimeSettingsStore.snapshot()"))
        #expect(runtime.contains("settings: serverSettings"))
        #expect(!runtime.contains("settings.mtp.mode = .auto"))
        #expect(runtime.contains("resolvedMTPLaunch("))
        #expect(runtime.contains("resolvedLoadConfiguration("))
        #expect(runtime.contains("resolvedMTPDraftStrategy("))
        #expect(runtime.contains("resolvedModelConfiguration("))
        #expect(runtime.contains("configuration: serverSettings.resolvedModelConfiguration("))
        #expect(runtime.contains("loadConfiguration: mtpPlan.loadConfiguration"))
        #expect(runtime.contains("draftStrategy: mtpPlan.draftStrategy"))
        #expect(runtime.contains("draftStrategy: holder.draftStrategy"))
        #expect(runtime.contains("params.draftStrategy = draftStrategy"))
        #expect(adapter.contains("draftStrategy: MLXLMCommon.DraftStrategy?"))
        #expect(adapter.contains("draftStrategy: draftStrategy"))

        let mtpSection = try Self.source("Views/Settings/ServerSettings/MTPSection.swift")
        #expect(mtpSection.contains("status: .engineReady"))
        #expect(!mtpSection.contains("status: .needsBridge"))

        let diagnosticsSnapshot = try Self.source("Services/ModelRuntime/BatchDiagnosticsSnapshot.swift")
        #expect(diagnosticsSnapshot.contains("nativeMTPDepthSummary"))
        #expect(diagnosticsSnapshot.contains("prefixHits"))
        #expect(diagnosticsSnapshot.contains("ssmCompanionReDerives"))

        let diagnosticsView = try Self.source("Views/Settings/ServerSettings/BatchDiagnosticsView.swift")
        #expect(diagnosticsView.contains("\"Native MTP\""))
        #expect(diagnosticsView.contains("\"Prefix hits / misses\""))
        #expect(diagnosticsView.contains("\"SSM hits / misses / re-derives\""))

        let httpHandler = try Self.source("Networking/HTTPHandler.swift")
        #expect(httpHandler.contains("\"draft_strategy\""))
        #expect(httpHandler.contains("\"native_mtp_depth\""))
        #expect(httpHandler.contains("\"native_mtp_status\""))
        #expect(httpHandler.contains("\"native_mtp_reason\""))
        #expect(httpHandler.contains("\"mlx_press\""))
        #expect(httpHandler.contains("\"generation_defaults\""))
        #expect(httpHandler.contains("\"last_effective_generation\""))
        #expect(httpHandler.contains("\"stage\": settings.stage"))
        #expect(httpHandler.contains("LocalGenerationDefaults.defaults(forModelId: summary.name)"))
        #expect(httpHandler.contains("lastEffectiveGenerationSettingsSnapshot()"))
        #expect(httpHandler.contains("path == \"/admin/generation-settings\""))
        #expect(httpHandler.contains("handleGenerationSettingsEndpoint("))
        #expect(httpHandler.contains("\"generation_defaults_by_model\""))
        #expect(httpHandler.contains("\"last_effective_generation_by_model\""))
        #expect(httpHandler.contains("It intentionally avoids `ModelRuntime`"))

        #expect(adapter.contains("recordPendingEffectiveGenerationSettings("))
        #expect(adapter.contains("stage: \"pending_preload\""))
        #expect(adapter.contains("stage: \"submitted_to_batch_engine\""))
        #expect(runtime.contains("MLXBatchAdapter.recordPendingEffectiveGenerationSettings("))
    }

    @Test("admin cache stats exposes resolved memory safety status without load refusal")
    func adminCacheStatsExposesResolvedMemorySafetyStatus() throws {
        let httpHandler = try Self.source("Networking/HTTPHandler.swift")
        let runtimeSettingsTests = try Self.source("Tests/Networking/ServerRuntimeSettingsStoreTests.swift")

        #expect(httpHandler.contains("@preconcurrency import MLXLMCommon"))
        #expect(httpHandler.contains("let runtimeSettings = ServerRuntimeSettingsStore.snapshot()"))
        #expect(httpHandler.contains("let memoryStatus = MemoryStatus.snapshot()"))
        #expect(httpHandler.contains("resolvedMemorySafetyPlan("))
        #expect(httpHandler.contains("\"memory_safety\""))
        #expect(httpHandler.contains("\"mode\": memorySafety.mode.rawValue"))
        #expect(httpHandler.contains("\"slider\": memorySafety.slider"))
        #expect(httpHandler.contains("\"allowed\": plan.blockingIssues.isEmpty"))
        #expect(httpHandler.contains("\"load_configuration\": loadConfigurationJSONObject(plan.loadConfiguration)"))
        #expect(httpHandler.contains("\"memory_status\": memoryStatusJSONObject(memoryStatus)"))
        #expect(httpHandler.contains("\"warnings\": plan.warnings"))
        #expect(httpHandler.contains("\"blocking_issues\": plan.blockingIssues.map(settingsIssueJSONObject)"))
        #expect(httpHandler.contains("case .disabled:"))
        #expect(httpHandler.contains("case .enabled(let coldFraction):"))
        #expect(httpHandler.contains("case .auto(let envFallback):"))
        #expect(!httpHandler.contains("throw LoadRefusedError("))

        #expect(runtimeSettingsTests.contains("memorySafety.mode == .safeAuto"))
        #expect(runtimeSettingsTests.contains("memorySafety.slider == 2"))
    }

    @Test("admin cache stats exposes a read-only storage location standards block")
    func adminCacheStatsExposesStorageLocationStandards() throws {
        let httpHandler = try Self.source("Networking/HTTPHandler.swift")
        let standards = try Self.source("Utils/StorageLocationStandards.swift")

        #expect(
            httpHandler.contains("\"storage_locations\": Self.storageLocationsJSONObject()")
        )
        #expect(httpHandler.contains("StorageLocationStandards.currentReport()"))

        // The audit surface is diagnostics-only for #1422: it must classify
        // and report, never migrate. Pin both the stable reason codes and the
        // absence of any filesystem mutation in the audit module.
        #expect(standards.contains("case homeDotDirectory = \"home_dot_directory\""))
        #expect(standards.contains("\"root_home_dot_directory_not_apple_spec\""))
        #expect(standards.contains("\"legacy_application_support_root_present\""))
        #expect(standards.contains("\"migration_decision_pending\""))
        #expect(standards.contains("\"spec_compliant\""))
        #expect(standards.contains("legacyApplicationSupportFolderName = \"com.dinoki.osaurus\""))
        #expect(!standards.contains("copyItem"))
        #expect(!standards.contains("moveItem"))
        #expect(!standards.contains("removeItem"))
        #expect(!standards.contains("createDirectory"))
    }

    @Test("ModelRuntime does not repair reasoning parser output")
    func modelRuntimeDoesNotRepairReasoningParserOutput() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")
        let scrubberPath = Self.packageRoot()
            .appendingPathComponent("Services/ModelRuntime/ThinkTagScrubber.swift")
            .path

        #expect(!FileManager.default.fileExists(atPath: scrubberPath))
        #expect(!runtime.contains("ThinkTagScrubber"))
        #expect(!runtime.contains(".scrub("))
        #expect(!runtime.contains("scrubber.flush"))
        #expect(runtime.contains("case .reasoning(let s):"))
        #expect(runtime.contains("StreamingReasoningHint.encode(s)"))
    }

    @Test("Chat UI routes parsed reasoning only through the reasoning sentinel")
    func chatUIRoutesParsedReasoningOnlyThroughReasoningSentinel() throws {
        let chatView = try Self.source("Views/Chat/ChatView.swift")
        let processor = try Self.source("Utils/StreamingDeltaProcessor.swift")

        let reasoningDecode = try #require(chatView.range(of: "StreamingReasoningHint.decode(delta)"))
        let receiveReasoning = try #require(chatView.range(of: "processor.receiveReasoning(reasoning)"))
        let contentDelta = try #require(chatView.range(of: "processor.receiveDelta(delta)"))
        #expect(reasoningDecode.lowerBound < receiveReasoning.lowerBound)
        #expect(receiveReasoning.lowerBound < contentDelta.lowerBound)
        #expect(!chatView.contains("processor.receiveDelta(reasoning)"))
        #expect(!chatView.contains("reasoning.contains(\"thought\")"))
        #expect(!chatView.contains("reasoning.contains(\"<|channel>"))

        let receiveStart = try #require(processor.range(of: "func receiveReasoning(_ text: String)"))
        let receiveEnd = try #require(
            processor.range(
                of: "    }\n\n    /// Force-flush",
                range: receiveStart.upperBound ..< processor.endIndex
            )
        )
        let receiveBody = String(processor[receiveStart.lowerBound ..< receiveEnd.upperBound])
        #expect(receiveBody.contains("appendThinking(text)"))
        #expect(!receiveBody.contains("appendContent"))
        #expect(!receiveBody.contains("<think"))
        #expect(!receiveBody.contains("<|channel"))
        #expect(!receiveBody.contains("thought"))
    }

    @Test("ChatEngine stream wrapper does not accumulate reasoning sentinels as visible response text")
    func chatEngineStreamWrapperKeepsReasoningOutOfVisibleAccumulator() throws {
        let chatEngine = try Self.source("Services/Chat/ChatEngine.swift")
        let reasoningDecode = try #require(
            chatEngine.range(of: "if let reasoning = StreamingReasoningHint.decode(delta)")
        )
        let yieldReasoning = try #require(
            chatEngine.range(
                of: "continuation.yield(delta)\n                        continue",
                range: reasoningDecode.upperBound ..< chatEngine.endIndex
            )
        )
        let visibleAppend = try #require(chatEngine.range(of: "responseAccumulator.append(delta)"))
        let textEstimate = try #require(chatEngine.range(of: "let estimated = TokenEstimator.estimate(delta)"))

        #expect(reasoningDecode.lowerBound < yieldReasoning.lowerBound)
        #expect(yieldReasoning.lowerBound < visibleAppend.lowerBound)
        #expect(yieldReasoning.lowerBound < textEstimate.lowerBound)
    }

    @Test("ChatEngine completeChat preserves reasoning_content before generic sentinel filtering")
    func chatEngineCompleteChatPreservesReasoningContentBeforeSentinelFiltering() throws {
        let chatEngine = try Self.source("Services/Chat/ChatEngine.swift")

        let toolStreamStart = try #require(chatEngine.range(of: "let stream = try await toolSvc.streamWithTools("))
        let toolResponseStart = try #require(
            chatEngine.range(
                of: "let outputTokens = TokenEstimator.estimate(text)",
                range: toolStreamStart.upperBound ..< chatEngine.endIndex
            )
        )
        let toolSlice = chatEngine[toolStreamStart.lowerBound ..< toolResponseStart.lowerBound]
        let toolReasoning = try #require(
            toolSlice.range(of: "if let reasoningDelta = StreamingReasoningHint.decode(delta)")
        )
        let toolSentinel = try #require(toolSlice.range(of: "if StreamingToolHint.isSentinel(delta)"))
        #expect(toolReasoning.lowerBound < toolSentinel.lowerBound)

        let plainStreamStart = try #require(chatEngine.range(of: "let stream = try await service.streamDeltas("))
        let plainResponseStart = try #require(
            chatEngine.range(
                of: "let outputTokens = authoritativeOutputTokens",
                range: plainStreamStart.upperBound ..< chatEngine.endIndex
            )
        )
        let plainSlice = chatEngine[plainStreamStart.lowerBound ..< plainResponseStart.lowerBound]
        let plainReasoning = try #require(
            plainSlice.range(of: "if let reasoningDelta = StreamingReasoningHint.decode(delta)")
        )
        let plainSentinel = try #require(plainSlice.range(of: "if StreamingToolHint.isSentinel(delta)"))
        #expect(plainReasoning.lowerBound < plainSentinel.lowerBound)

        #expect(chatEngine.contains("reasoning_content: reasoning.isEmpty ? nil : reasoning"))
    }

    @Test("ModelRuntime wires idle residency around model leases")
    func modelRuntimeWiresIdleResidencyAroundLeases() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")
        let manager = try Self.source("Services/ModelRuntime/ModelResidencyManager.swift")

        #expect(runtime.contains("ModelResidencyManager.shared.markActive(modelName: modelName)"))
        #expect(runtime.contains("ModelResidencyManager.shared.markActive(modelName: holder.name)"))
        #expect(runtime.contains("private func scheduleIdleResidency(for modelName: String) async"))
        #expect(runtime.contains("ServerConfigurationStore.load()?.modelIdleResidencyPolicy"))
        #expect(runtime.contains("ModelResidencyManager.shared.scheduleIdleUnload"))
        #expect(runtime.contains("ModelLease.shared.count(for: name)"))
        #expect(runtime.contains("await ModelResidencyManager.shared.cancel(modelName: name)"))
        #expect(runtime.contains("await ModelResidencyManager.shared.cancelAll()"))
        #expect(manager.contains("guard await leaseCount(modelName) == 0"))
        #expect(manager.contains("guard await isResident(modelName)"))
    }

    @Test("RuntimeConfig snapshot does not hop to MainActor before model load")
    func runtimeConfigSnapshotAvoidsMainActorPreLoadHop() throws {
        let config = try Self.source("Services/ModelRuntime/RuntimeConfig.swift")

        #expect(!config.contains("ServerController.sharedConfiguration()"))
        #expect(!config.contains("MainActor.run"))
        #expect(config.contains("diskBackedServerConfiguration()"))
        #expect(config.contains("OsaurusPaths.serverConfigFile()"))
    }

    @Test("UI and health expose model idle residency")
    func uiAndHealthExposeModelIdleResidency() throws {
        let settings = try Self.source(
            "Views/Settings/ServerSettings/ModelResidencySection.swift"
        )
        let health = try Self.source("Networking/HTTPHandler.swift")
        let windows = try Self.source("Managers/Chat/ChatWindowManager.swift")

        // Eviction + idle residency live in the Server → Settings
        // tab's per-section file `ModelResidencySection`.
        #expect(settings.contains("modelIdleResidencyPolicy"))
        #expect(settings.contains("Keep Model Loaded"))
        #expect(settings.contains("ModelIdleResidencyPolicy.presets"))
        #expect(health.contains("\"resident_models\": residentModels"))
        #expect(health.contains("\"idle_unload_at\""))
        #expect(health.contains("\"idle_seconds_remaining\""))
        #expect(windows.contains("modelIdleResidencyPolicy"))
        #expect(windows.contains("if idlePolicy == .immediately"))
        #expect(
            windows.contains("let found = ModelManager.findInstalledModel(named: model)")
                && windows.contains("return found.name"),
            "Chat UI active-model cleanup must use ModelRuntime's canonical repo-tail cache key, not the raw picker id."
        )
    }

    @Test("Local bundle config readers preserve discovered bundle paths")
    func localBundleConfigReadersPreserveDiscoveredBundlePaths() throws {
        let defaults = try Self.source("Services/LocalGenerationDefaults.swift")
        let reasoning = try Self.source("Services/LocalReasoningCapability.swift")
        let manager = try Self.source("Managers/Model/ModelManager.swift")

        #expect(manager.contains("findInstalledMLXModel(named name: String) -> MLXModel?"))
        #expect(manager.contains("MLXModel.localDirectory"))
        #expect(defaults.contains("ModelManager.findInstalledMLXModel(named: modelId)"))
        #expect(defaults.contains("return found.localDirectory"))
        #expect(defaults.contains("readSmallConfigFile"))
        #expect(!defaults.contains("Data(contentsOf:"))
        #expect(!defaults.contains("parts.reduce(base)"))
        #expect(reasoning.contains("ModelManager.findInstalledMLXModel(named: modelId)"))
        #expect(reasoning.contains("return found.localDirectory"))
        #expect(reasoning.contains("readSmallConfigFile"))
        #expect(!reasoning.contains("Data(contentsOf:"))
        #expect(!reasoning.contains("String(contentsOf:"))
        #expect(!reasoning.contains("parts.reduce(base)"))
    }

    @Test("Resident same-model turns do not flash model-loading UI")
    func residentSameModelTurnsDoNotFlashModelLoadingUI() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")

        #expect(runtime.contains("let shouldReportModelLoad = modelCache[modelName] == nil"))
        #expect(
            runtime.contains(
                "if shouldReportModelLoad {\n            InferenceProgressManager.shared.modelLoadWillStartAsync()"
            )
        )
        #expect(
            runtime.contains(
                "if shouldReportModelLoad {\n            InferenceProgressManager.shared.modelLoadDidFinishAsync()"
            )
        )
        #expect(
            runtime.contains("must not flash the UI back to\n        // \"Loading Model...\" on every message"),
            "Hot resident chat turns must not emit the model-loading phase; users read that as a reload."
        )
    }

    @Test("Chat UI sends accumulated history and marks implicit sampling without forcing native MTP")
    func chatUISendsAccumulatedHistoryAndMarksImplicitSamplingWithoutForcingNativeMTP() throws {
        let chatView = try Self.source("Views/Chat/ChatView.swift")

        let buildMessages = try #require(chatView.range(of: "func buildMessages() -> [ChatMessage]"))
        let streamRequest = try #require(chatView.range(of: "var req = ChatCompletionRequest("))
        let implicitSampling = try #require(chatView.range(of: "req.samplingParametersAreImplicit = true"))

        #expect(
            chatView.contains("for (index, t) in turns.enumerated()"),
            "Chat UI must build requests from accumulated turns, not just the newest user text."
        )
        #expect(
            chatView.contains("if !sys.isEmpty { msgs.append(ChatMessage(role: \"system\", content: sys)) }"),
            "Chat UI request history must retain the composed system/context prefix."
        )
        // Indentation-tolerant regex: the loop body must (a) gate the
        // append on the optional return from `turnToMessage`, and (b)
        // forward the resulting message via `msgs.append(msg)`. Pinning
        // the exact whitespace was fragile — wrapping the surrounding
        // closure in another layer (as Phase A/B did) silently broke
        // the literal even though the contract was preserved.
        let appendRegex = try NSRegularExpression(
            pattern: #"if let msg = turnToMessage\(t, isLastTurn: isLastTurn\) \{\s+msgs\.append\(msg\)\s+\}"#
        )
        let appendNSRange = NSRange(chatView.startIndex ..< chatView.endIndex, in: chatView)
        #expect(
            appendRegex.firstMatch(in: chatView, range: appendNSRange) != nil,
            "Every non-empty prior user/assistant/tool turn should be converted into ChatMessage history."
        )
        #expect(buildMessages.lowerBound < streamRequest.lowerBound)
        #expect(streamRequest.lowerBound < implicitSampling.lowerBound)
        #expect(
            chatView.contains("temperature: effectiveTemp"),
            "The UI may pass the agent/profile temperature, but implicit sampling must be preserved by the runtime rather than rewritten to greedy native-MTP defaults."
        )
        #expect(
            chatView.contains("tools: toolSpecs.isEmpty ? nil : toolSpecs"),
            "Chat UI should only send tool schemas when the composer resolved a non-empty tool set."
        )
        #expect(
            chatView.contains("let requestedToolChoice = ChatToolChoicePolicy.resolve(")
                && chatView.contains("tool_choice: requestedToolChoice"),
            "Chat UI should route explicit tool-use prompts through the shared policy instead of hard-coding auto for every tool-enabled turn."
        )
        #expect(
            chatView.contains("tools: toolSpecs,")
                && chatView.contains("userText: trimmed,")
                && chatView.contains("attempt: attempt"),
            "Chat UI tool-choice policy must see the resolved tools, original user text, and attempt count so first-turn required routing cannot become a repeated tool loop."
        )
        #expect(
            chatView.contains("finalReq.samplingParametersAreImplicit = true"),
            "Tool-budget wrap-up calls use the same implicit-sampling contract as normal UI turns."
        )
    }

    @Test("Tools settings renders runtime-managed folder and sandbox tools")
    func toolsSettingsShowsRuntimeManagedToolRows() throws {
        let toolsView = try Self.source("Views/Plugin/ToolsManagerView.swift")

        #expect(
            toolsView.contains("@State private var runtimeManagedToolEntries"),
            "Tools settings must keep a visible runtime-managed tool snapshot so folder/sandbox chat tools do not look unavailable."
        )
        #expect(
            toolsView.contains("ToolRegistry.shared.runtimeManagedToolNames")
                && toolsView.contains("ToolRegistry.shared.builtInSandboxToolNamesSnapshot"),
            "Tools settings must source runtime-managed and built-in sandbox tools from ToolRegistry, not plugin/provider catalogs."
        )
        #expect(
            toolsView.contains("Runtime Tools")
                && toolsView.contains("Built-in Sandbox Tools"),
            "Tools settings must render explicit rows for chat-visible runtime tools."
        )
        #expect(
            toolsView.contains("RuntimeManagedToolEntryRow")
                && toolsView.contains("badge: runtimeBadge(for: entry)")
                && (toolsView.contains("badge: \"Sandbox\"")
                    || toolsView.contains("badge: L(\"Sandbox\")")),
            "Runtime-managed tools must be visible as operational rows without pretending they are normal plugin toggle rows."
        )
        #expect(
            toolsView.contains(".available: availableShown + runtimeShown")
                && toolsView.contains(
                    ".sandbox: SandboxPluginLibrary.shared.plugins.count + builtInSandboxToolEntries.count"
                ),
            "Tools tab badges must count the runtime rows they render so Settings cannot show 0 while chat has folder/sandbox tools."
        )
    }

    @Test("local decode loop keeps tool schemas for parser-side argument validation")
    func localDecodeLoopKeepsToolSchemasForParserValidation() throws {
        let chatEngine = try Self.source("Services/Chat/ChatEngine.swift")
        let protocolErrors = try Self.source("Networking/HTTPProtocolErrors.swift")
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")
        let registry = try Self.source("Tools/ToolRegistry.swift")

        #expect(
            adapter.contains("lmInput = prepared.withToolSchemas(toolsSpec)"),
            "MLXBatchAdapter must carry the same tool schemas from prompt rendering into vmlx's decode loop so DSML/JSON fallback parsing can validate required arguments."
        )
        #expect(
            adapter.contains("toolChoice: toolChoice"),
            "MLXBatchAdapter must pass the resolved tool_choice into prompt preparation so required local tool calls can reach family templates."
        )
        #expect(
            adapter.contains("context[\"tool_choice\"] = \"required\"")
                && adapter.contains("case .required, .function(_)"),
            "Required or named local tool_choice must become template context instead of being reduced to a tools-available-only prompt."
        )
        #expect(
            adapter.contains("context[\"tool_choice_name\"] = toolChoiceName")
                && adapter.contains("private static func requiredToolChoiceName(")
                && adapter.contains("case .function(let target):")
                && adapter.contains("guard let toolsSpec, toolsSpec.count == 1"),
            "Required/named local tool_choice must pass the target tool name into vmlx template context so Nemotron-family required tool templates do not fall back to generic placeholders."
        )
        let tokenizerLoader = try Self.source("Services/ModelRuntime/SwiftTransformersTokenizerLoader.swift")
        #expect(
            tokenizerLoader.contains("let toolChoiceRequired =")
                && tokenizerLoader.contains(
                    "Self.deepseekV4String(additionalContext?[\"tool_choice\"]) == \"required\""
                )
                && tokenizerLoader.contains("toolChoiceRequired: toolChoiceRequired"),
            "DSV4 native prompt rendering must pass required tool_choice into DeepseekV4ChatEncoder so second-turn/named required tool calls keep the DSML must-call directive."
        )
        #expect(
            !tokenizerLoader.contains("dsv4Messages[idx].task = \"action\"")
                && tokenizerLoader.contains("toolChoiceRequired: toolChoiceRequired"),
            "DSV4 required/named tool_choice must pass through the required-template contract; the Swift encoder must not mutate historical messages with task=action. The pinned vMLX fallback may still open the native DSV4 action token at the current assistant generation rail."
        )
        #expect(
            tokenizerLoader.contains("&& upstream.bosToken == Self.dsv4Bos")
                && !tokenizerLoader.contains("convertTokenToId(Self.dsv4Bos)")
                && !tokenizerLoader.contains("convertTokenToId(Self.dsv4Eos)"),
            "DSV4 template routing must require the actual DSV4 BOS token; token-id convertibility is too broad and can misroute Nemotron Omni into DSML placeholders."
        )
        #expect(
            registry.contains("invalidToolArgumentsEnvelope")
                && registry.contains("\"invalid_tool_arguments\""),
            "ToolRegistry must turn parser-side invalid tool arguments into a structured invalid_args envelope instead of executing the tool body."
        )
        #expect(
            chatEngine.contains("private static func requiresLocalToolCall")
                && chatEngine.contains("case .required, .function")
                && chatEngine.contains("The model did not produce a valid required tool call.")
                && chatEngine.contains("suppressed_content_preview"),
            "Required/named local tool_choice turns must fail closed if vMLX reaches EOS without a parsed tool invocation; malformed model prose must not leak as a normal assistant response."
        )
        #expect(
            protocolErrors.contains(#"(error as NSError).domain == "OsaurusToolChoice""#)
                && protocolErrors.contains("return .badRequest")
                && protocolErrors.contains(#"return "invalid_request_error""#),
            "Fail-closed required-tool turns are client/request errors, not generic server crashes."
        )
    }

    @Test("local streamWithTools terminates on parsed tool invocation before leaking post-tool prose")
    func localStreamWithToolsTerminatesOnParsedToolInvocationBeforePostToolProseLeak() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")
        let streamStart = try #require(
            runtime.range(of: "func streamWithTools("),
            "ModelRuntime must retain the local streamWithTools path used by Chat UI streaming."
        )
        let streamEnd = try #require(
            runtime[streamStart.lowerBound...].range(of: "// MARK: - Static helpers"),
            "The streamWithTools source slice should end before static helper declarations."
        )
        let streamWithTools = runtime[streamStart.lowerBound ..< streamEnd.lowerBound]
        let toolCase = try #require(
            streamWithTools.range(of: "case .toolInvocation(let name, let argsJSON):"),
            "ModelRuntime.streamWithTools must handle parsed vMLX toolInvocation events."
        )
        let afterToolCase = streamWithTools[toolCase.lowerBound...]

        #expect(
            afterToolCase.contains("ServiceToolInvocation(")
                && afterToolCase.contains("toolName: name")
                && afterToolCase.contains("jsonArguments: argsJSON")
                && afterToolCase.contains("continuation.finish(throwing: tool)"),
            "streamWithTools must capture the parsed vMLX tool call (name + args) into the pending ServiceToolInvocation and finish the stream by throwing it so the Chat UI dispatches the tool."
        )
        #expect(
            afterToolCase.contains("return"),
            "After surfacing the parsed tool invocation the producer task must return rather than run on."
        )
        // The real no-leak invariant: once a tool call is pending, model text is
        // gated on `pendingTool == nil` and never yielded, so DSV4 pseudo-tool
        // prose emitted after the tool event cannot reach the UI/consumer. The
        // producer keeps draining only to forward the terminal `.completionInfo`
        // decode stats (tok/s + token count) before throwing — tool-call turns
        // must not drop their telemetry.
        #expect(
            streamWithTools.contains("if pendingTool == nil, !s.isEmpty { continuation.yield(s) }"),
            "Post-tool model text must be gated on `pendingTool == nil` so pseudo-tool prose is suppressed once a tool call is parsed, even while draining for end-of-step stats."
        )
        #expect(
            !afterToolCase.contains("pendingTools.append"),
            "The local streaming path must not batch-collect tool invocations after a parsed tool event; batch collection belongs to the non-streaming tool response path."
        )
    }

    @Test("ModelRuntime does not block model-ready on hidden Hy3 warmup generation")
    func modelRuntimeDoesNotBlockModelReadyOnHy3WarmupGeneration() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")

        #expect(
            !runtime.contains("runPostLoadWarmupIfNeeded("),
            "ModelRuntime must not await a hidden Hy3 generation inside loadContainer; it makes the UI report first-forward materialization as model loading / TTFT"
        )
        #expect(!runtime.contains("loadContainer: post-load warmup completed"))
        #expect(!runtime.contains("input.additionalContext = [\"reasoning_effort\": \"no_think\"]"))
    }

    @Test("MLXBatchAdapter does not force hidden reasoning defaults")
    func mlxBatchAdapterDoesNotForceHiddenReasoningDefaults() throws {
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")
        let modelService = try Self.source("Services/Inference/ModelService.swift")
        let tokenizerLoader = try Self.source("Services/ModelRuntime/SwiftTransformersTokenizerLoader.swift")
        let reasoningCapability = try Self.source("Services/LocalReasoningCapability.swift")

        #expect(
            adapter.contains("normalizedReasoningEffort != nil || disableThinking != nil"),
            "DSV4 reasoning context should only be synthesized when the client requested reasoning controls."
        )
        #expect(
            !adapter.contains("effort = \"instruct\""),
            "DSV4 must not silently force instruct/no-thinking mode when the request omitted reasoning controls."
        )
        #expect(
            !adapter.contains("context[\"enable_thinking\"] = true\n        return context"),
            "Generic local chat must not silently force enable_thinking=true."
        )
        #expect(
            !adapter.contains(
                "context[\"enable_thinking\"] = hasPositiveReasoningEffort\n            if hasPositiveReasoningEffort"
            ),
            "Family-specific reasoning profiles must not force enable_thinking=false by writing a false boolean when no positive effort was requested."
        )
        #expect(
            adapter.contains("if ModelFamilyNames.isZayaFamily(modelName)")
                && adapter.contains("context[\"enable_thinking\"] = false"),
            "ZAYA text bundles are the explicit exception: their profile default is a closed/no-thinking prompt, so omitted reasoning controls must reach vmlx as enable_thinking=false."
        )
        #expect(
            adapter.contains("if ModelFamilyNames.isQwenFamily(modelName)")
                && adapter.contains("context[\"enable_thinking\"] = false"),
            "Qwen local chat is an explicit exception: live tool-history rows must default to the closed/no-thinking rail instead of hidden reasoning-only length stops."
        )
        #expect(
            adapter.contains("if ModelFamilyNames.isNemotronThinkingFamily(modelName)")
                && adapter.contains("context[\"enable_thinking\"] = false"),
            "Nemotron reasoning bundles are the explicit hybrid exception: live ordinary chat must default to the closed/no-thinking rail instead of hidden reasoning-only output."
        )
        #expect(
            adapter.contains("if ModelFamilyNames.isGemmaFamily(modelName)")
                && adapter.contains("context[\"enable_thinking\"] = false"),
            "Gemma4 bundles must default to the closed/no-thinking rail for local API requests, matching their UI profile default without parser-side output repair."
        )
        #expect(
            !adapter.contains("dsv4MaxReasoningRepetitionPenalty")
                && !adapter.contains("repeated \"thinking\" token loop"),
            "Decode-loop problems must not be hidden behind DSV4-specific forced repetition-penalty guards."
        )
        #expect(
            adapter.contains("engineDefaults.temperature")
                && !adapter.contains("runtimeTemperature ?? 0.7"),
            "Local chat sampler fallback must use vmlx GenerateParameters defaults, not Osaurus-specific invented temperature defaults."
        )
        #expect(
            adapter.contains("engineDefaults.topP")
                && adapter.contains("engineDefaults.topK")
                && adapter.contains("engineDefaults.minP")
                && !adapter.contains("runtimeTopP ?? 1.0")
                && !adapter.contains("runtimeTopK ?? 0")
                && !adapter.contains("runtimeMinP ?? 0"),
            "Local chat sampler fallback must use vmlx GenerateParameters defaults for topP/topK/minP instead of hardcoded Osaurus literals."
        )
        #expect(
            !adapter.contains("generation.samplingParametersAreImplicit {\n            return true"),
            "Implicit UI sampling must not authorize native-MTP greedy sampler rewrites."
        )
        #expect(
            !adapter.contains("temperature: useNativeMTPGreedyDefaults")
                && !adapter.contains("topP: useNativeMTPGreedyDefaults")
                && !adapter.contains("topK: useNativeMTPGreedyDefaults"),
            "Native-MTP compatibility must be handled by dropping draft mode, not by rewriting sampler parameters."
        )
        #expect(
            modelService.contains("If an acceleration path cannot honor them, it should fall back to"),
            "GenerationParameters.samplingParametersAreImplicit documentation must preserve the no-forced-sampler contract."
        )
        #expect(
            tokenizerLoader.contains("if isGemma {\n                throw error\n            }")
                && !tokenizerLoader.contains("} else if isGemma {\n                ordered = ["),
            "Gemma-family native template runtime errors must not silently fall back to Gemma4 tool/minimal templates."
        )
        #expect(
            !tokenizerLoader.contains("label: \"Gemma4RequiredTool\"")
                && !tokenizerLoader.contains(
                    "Self.requiresToolChoice(adjustedContext),\n            (env[\"VMLX_CHAT_TEMPLATE_FALLBACK_DISABLE\"] ?? \"0\") != \"1\"\n        {\n            return try fallback(\n                label: \"Gemma4"
                ),
            "Gemma4 required/named tool turns must not bypass the model-bundled native template with an Osaurus-forced Gemma4WithTools fallback."
        )
        #expect(
            reasoningCapability.contains("runtime code must not synthesize")
                && !reasoningCapability.contains("streaming prepend-think"),
            "Reasoning capability detection must not document or imply middleware-prepended thinking tags."
        )
    }

    @Test("Inference docs match max-batch hot-resize semantics")
    func inferenceDocsDescribeMaxBatchDefaultsAndHotResize() throws {
        let flags = try Self.source("Services/ModelRuntime/InferenceFeatureFlags.swift")
        let runtimeDoc = try Self.source("../../docs/INFERENCE_RUNTIME.md")
        let featuresDoc = try Self.source("../../docs/FEATURES.md")
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")

        #expect(flags.contains("Defaults to **1**"))
        #expect(flags.contains("return raw > 0 ? min(raw, 32) : 1"))
        #expect(runtimeDoc.contains("Defaults to `1`, clamped to `[1, 32]`"))
        #expect(runtimeDoc.contains("mutable at runtime"))
        #expect(runtimeDoc.contains("updateMaxBatchSize"))
        #expect(featuresDoc.contains("default `1`, clamped to `[1, 32]`"))
        #expect(featuresDoc.contains("hot-resized via `BatchEngine.updateMaxBatchSize(_:)`"))
        #expect(!runtimeDoc.contains("Defaults to `4`"))
        #expect(!featuresDoc.contains("default `4`"))
        #expect(adapter.contains("hot-resized BatchEngine"))
        #expect(adapter.contains("rejected updateMaxBatchSize"))
    }

    @Test("MiMo and N2 tool preflight does not walk external bundles")
    func mimoAndN2ToolPreflightAvoidsExternalBundleWalk() throws {
        let service = try Self.source("Services/Inference/MLXService.swift")
        let support = try #require(service.range(of: "nonisolated static func supportsLocalToolCalling"))
        let end =
            service.range(
                of: "private nonisolated static func localModelDirectory",
                range: support.lowerBound ..< service.endIndex
            )
            .map(\.lowerBound) ?? service.endIndex
        let body = String(service[support.lowerBound ..< end])
        let jangFastPath = try #require(body.range(of: "isKnownTextOnlyJANGRuntimeFamily"))
        let bundleLookup = try #require(body.range(of: "localModelDirectory(modelId: modelId)"))

        #expect(body.contains("if isKnownTextOnlyJANGRuntimeFamily(modelId: modelId)"))
        #expect(body.contains("return true"))
        #expect(
            jangFastPath.lowerBound < bundleLookup.lowerBound,
            "MiMo/N2 JANG tool preflight must short-circuit before external bundle metadata lookup."
        )
    }

    @Test("Gemma text tool preflight avoids media bundle reads")
    func gemmaTextToolPreflightAvoidsMediaBundleReads() throws {
        let service = try Self.source("Services/Inference/MLXService.swift")
        let validate = try #require(service.range(of: "static func validateRuntimePolicy"))
        let support = try #require(service.range(of: "nonisolated static func supportsLocalToolCalling"))

        let validateEnd =
            service.range(
                of: "nonisolated static func supportsLocalToolCalling",
                range: validate.lowerBound ..< service.endIndex
            )
            .map(\.lowerBound) ?? service.endIndex
        let validateBody = String(service[validate.lowerBound ..< validateEnd])
        #expect(
            validateBody.contains("let mediaModalities: Set<ModelRuntimeRequestModality> = [.vision, .video, .audio]")
        )
        #expect(validateBody.contains("if !modalities.isDisjoint(with: mediaModalities)"))

        let supportEnd =
            service.range(
                of: "private nonisolated static func localModelDirectory",
                range: support.lowerBound ..< service.endIndex
            )
            .map(\.lowerBound) ?? service.endIndex
        let supportBody = String(service[support.lowerBound ..< supportEnd])
        let gemmaFastPath = try #require(supportBody.range(of: "ModelFamilyNames.isGemmaFamily"))
        let bundleLookup = try #require(supportBody.range(of: "localModelDirectory(modelId: modelId)"))
        #expect(
            gemmaFastPath.lowerBound < bundleLookup.lowerBound,
            "Gemma tool preflight must not synchronously read external bundle metadata."
        )
    }

    @Test("Runtime docs keep upstream Metal fault boundaries explicit")
    func inferenceDocsKeepUpstreamMetalFaultBoundaries() throws {
        let runtimeDoc = try Self.source("../../docs/INFERENCE_RUNTIME.md")
        let lingDoc = try Self.source("../../docs/LING_JANGTQ2_LONG_PROMPT_CRASH.md")

        #expect(runtimeDoc.contains("BailingLinearAttention.recurrentGLA"))
        #expect(runtimeDoc.contains("enableSSMReDerive=true"))
        #expect(runtimeDoc.contains("convertToBFloat16(model:)"))
        #expect(runtimeDoc.contains("mlx::core::Fence::wait"))
        #expect(runtimeDoc.contains("AGX::ComputeContext::endComputePass"))
        #expect(lingDoc.contains("EXC_BAD_ACCESS"))
        #expect(lingDoc.contains("BatchEngine.stepPrefill"))
    }

    @Test("SwiftUI previews are gated out of CLI SwiftPM builds")
    func swiftUIPreviewsArePreviewMacroGated() throws {
        var failures: [String] = []

        for url in try Self.swiftFiles(under: "Views") {
            let source = try String(contentsOf: url, encoding: .utf8)
            let lines = source.components(separatedBy: .newlines)
            let previewLines = lines.indices.filter { lines[$0].hasPrefix("#Preview") }
            guard let firstPreviewLine = previewLines.first,
                let lastPreviewLine = previewLines.last
            else {
                continue
            }

            let relativePath = url.path.replacingOccurrences(
                of: Self.packageRoot().path + "/",
                with: ""
            )

            let guardLine = firstPreviewLine > 0 ? lines[firstPreviewLine - 1] : ""
            if guardLine != "#if DEBUG && canImport(PreviewsMacros)" {
                failures.append("\(relativePath): first #Preview is not preceded by the PreviewsMacros gate")
                continue
            }

            var braceDepth = 0
            var sawOpeningBrace = false
            var previewCloseLine: Int?
            for index in lastPreviewLine ..< lines.count {
                for character in lines[index] {
                    switch character {
                    case "{":
                        braceDepth += 1
                        sawOpeningBrace = true
                    case "}":
                        if sawOpeningBrace {
                            braceDepth -= 1
                        }
                    default:
                        break
                    }
                }

                if sawOpeningBrace, braceDepth == 0 {
                    previewCloseLine = index
                    break
                }
            }

            guard let previewCloseLine else {
                failures.append("\(relativePath): last #Preview block did not close")
                continue
            }

            let searchStart = previewCloseLine + 1
            let nextContentLine =
                searchStart < lines.endIndex
                ? lines.indices[searchStart...]
                    .first { !lines[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                : nil
            if nextContentLine == nil || lines[nextContentLine!] != "#endif" {
                failures.append(
                    "\(relativePath): PreviewsMacros gate must close immediately after the last preview block"
                )
            }
        }

        if !failures.isEmpty {
            let message = failures.joined(separator: "\n")
            Issue.record("\(message)")
        }
    }

    @Test("Sentry inference breadcrumbs expose token count without prompt-content filtering")
    func sentryInferenceBreadcrumbsExposeTokenCountWithoutPromptFilter() throws {
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")
        let crashReporting = try Self.source("Services/CrashReportingService.swift")

        #expect(
            crashReporting.contains("guard SentrySDK.isEnabled else { return }"),
            "Breadcrumb recording must no-op before Sentry starts; otherwise keychain-free/dev runs log SDK-disabled breadcrumb errors."
        )
        #expect(adapter.contains("input_tokens=\\(prepared.promptTokens.count)"))
        #expect(
            !adapter.contains("message: \"begin model=\\(modelName) promptTokens="),
            "Sentry scrubs breadcrumbs containing prompt-like fields as content; token counts must remain visible for OOM/context-growth triage"
        )
        #expect(adapter.contains("submit model=\\(modelName) batch=\\(maxBatchSize)"))
    }
}
