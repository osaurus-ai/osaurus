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

        #expect(source.contains("let embeddingInitTask = Task.detached(priority: .utility)"))
        #expect(source.contains("await serverController.startServer()"))
        #expect(
            source.range(of: "let embeddingInitTask = Task {") == nil,
            "startup memory/vector initialization must not inherit MainActor and block server startup"
        )
    }

    @Test("AppDelegate binds HTTP server before Parakeet/CoreML startup")
    func appDelegateStartsServerBeforeSpeechAutoload() throws {
        let source = try Self.source("AppDelegate.swift")
        let serverTask = try #require(source.range(of: "let serverStartupTask = Task { @MainActor in"))
        let serverStart = try #require(source.range(of: "await serverController.startServer()"))
        let modelCachePrewarm = try #require(source.range(of: "await ModelPickerItemCache.shared.prewarmModelCache()"))
        let schedulerStart = try #require(source.range(of: "NextRunScheduler.shared.start()"))
        let speechAutoload = try #require(source.range(of: "await SpeechService.shared.autoLoadIfNeeded()"))

        #expect(serverTask.lowerBound < modelCachePrewarm.lowerBound)
        #expect(serverStart.lowerBound < schedulerStart.lowerBound)
        #expect(serverStart.lowerBound < speechAutoload.lowerBound)
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
        #expect(!source.contains("prewarmCurrentKeyOffCooperativeExecutor()"))
        #expect(!source.contains("let storageKeyPrewarmTask"))
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
        #expect(store.contains("StorageKeyManager.shared.hasCachedKey"))
        #expect(store.contains("Chat history unavailable: storage key is not already unlocked"))
    }

    @Test("chat history writer skips persistence unless storage key is already unlocked")
    func chatHistoryWriterSkipsPersistenceUnlessStorageKeyCached() throws {
        let source = try Self.source("Storage/ChatHistoryWriter.swift")
        let gate = try #require(source.range(of: "StorageKeyManager.shared.hasCachedKey"))
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
            source.range(of: "Task { @MainActor in\n            guard StorageKeyManager.shared.hasCachedKey else")
        )
        let schedulerStart = try #require(source.range(of: "NextRunScheduler.shared.start()"))

        #expect(schedulerBlock.lowerBound < schedulerStart.lowerBound)
        #expect(!source.contains("storageKeyPrewarmTask"))
        #expect(source.contains("Scheduler disabled: storage key is not already unlocked"))
    }

    @Test("startup avoids storage-key reads and background Keychain queries skip authentication UI")
    func startupAvoidsStorageKeyReadsAndBackgroundKeychainsSkipAuthenticationUI() throws {
        let storageKey = try Self.source("Identity/StorageKeyManager.swift")
        #expect(storageKey.contains("kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip"))
        #expect(storageKey.contains("cachedReadFailureStatus"))
        #expect(storageKey.contains("errSecInteractionNotAllowed"))
        #expect(storageKey.contains("public var hasCachedKey: Bool"))

        let appDelegate = try Self.source("AppDelegate.swift")
        // The migrator used to be the implicit key-cache warmer via its
        // own `currentKey()` call, but `runIfNeeded` short-circuits on
        // launches with no pending migration. The synchronous prewarm
        // here is the explicit guarantee that downstream `hasCachedKey`
        // guards (chat history, memory, schedulers) never fail closed
        // simply because nothing happened to read the key first.
        #expect(appDelegate.contains("StorageKeyManager.shared.prewarmCurrentKey()"))
        #expect(!appDelegate.contains("prewarmCurrentKeyOffCooperativeExecutor()"))
        #expect(!appDelegate.contains("let storageKeyPrewarmTask"))
        #expect(appDelegate.contains("Storage-dependent search/index services disabled"))
        #expect(appDelegate.contains("guard StorageKeyManager.shared.hasCachedKey else"))

        let chatSessions = try Self.source("Managers/Chat/ChatSessionsManager.swift")
        #expect(!chatSessions.contains("prewarmCurrentKeyOffCooperativeExecutor()"))

        let apiKeys = try Self.source("Identity/APIKeyManager.swift")
        #expect(apiKeys.contains("kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip"))
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

        let agents = try Self.source("Managers/AgentManager.swift")
        let migrationStart = try #require(agents.range(of: "private func migrateAgentAddressesIfNeeded()"))
        let migrationEnd = try #require(
            agents.range(
                of: "    }\n\n    /// One-time migration: read the legacy active.txt file",
                range: migrationStart.upperBound ..< agents.endIndex
            )
        )
        let migrationBody = String(agents[migrationStart.lowerBound ..< migrationEnd.upperBound])
        #expect(!migrationBody.contains("assignAddress(to: agent)"))
        #expect(!migrationBody.contains("MasterKey.getPrivateKey"))

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
        #expect(source.contains("allowPreflight: options.wantsPreflight"))
        #expect(source.contains("allowPreflight: Bool = true"))
        #expect(source.contains("query: extractPreflightQuery(from: messages)"))
        #expect(source.contains("messages: messages"))
        #expect(source.contains("cachedPreflight: allowPreflight ? nil : .empty"))
        #expect(source.contains("memorySection: composed.memorySection"))
        #expect(source.contains("SystemPromptComposer.injectMemoryPrefix(ctx.memorySection, into: &messages)"))
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
        let sandboxStart = try #require(composer.range(of: "if executionMode.usesSandboxTools"))
        let sandboxEnd = try #require(
            composer.range(
                of: "} else if let folder = executionMode.folderContext",
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

        for path in [
            "Services/Provider/RemoteProviderKeychain.swift",
            "Services/Keychain/AgentSecretsKeychain.swift",
            "Services/Keychain/ToolSecretsKeychain.swift",
            "Services/MCP/MCPProviderKeychain.swift",
        ] {
            let source = try Self.source(path)
            let queryCount =
                source.components(separatedBy: "kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip").count
                - 1
            let contextCount =
                source.components(
                    separatedBy: "kSecUseAuthenticationContext as String: KeychainQueryHelpers.nonInteractiveContext()"
                ).count - 1
            #expect(contextCount >= queryCount)
        }

        let storageKey = try Self.source("Identity/StorageKeyManager.swift")
        #expect(storageKey.contains("kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip"))
        #expect(!storageKey.contains("KeychainQueryHelpers.nonInteractiveContext()"))
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

    @Test("vmlx pin uses consolidated package with runtime hardening")
    func vmlxPinIncludesRuntimeHardening() throws {
        let manifest = try Self.source("Package.swift")
        let workspaceResolved = try Self.source(
            "../../osaurus.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        let appResolved = try Self.source(
            "../../App/osaurus.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )

        // This revision keeps the consolidated vmlx-swift pin for Osaurus
        // with vendored Jinja/Hub/Tokenizers/Transformers exposed through
        // VMLX-prefixed products, plus the Qwen3.6 MXFP affine metadata and
        // MoE router-gate load hardening. That avoids Xcode PIF
        // duplicate-product collisions with the app graph while keeping yyjson
        // as one shared C dependency. Osaurus must not carry SwiftPM
        // moduleAliases for that collision.
        let currentVmlxRevision = "3cdd9f38ef4a57b53cbac434261b6bac8e038b31"
        #expect(manifest.contains(currentVmlxRevision))
        #expect(workspaceResolved.contains(currentVmlxRevision))
        #expect(appResolved.contains(currentVmlxRevision))
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
    /// `.info`, fixing the stream-stays-open UX. We KEEP the opt-out
    /// regardless because osaurus's chat workload mutates the system
    /// prefix every turn (memory injection, preflight capability search,
    /// dynamic skills) so the SSM cache rarely lands a boundary-matching
    /// hit on the next turn — re-derive cost is paid without warm-cache
    /// payoff. If a future refactor drops or inverts the knob, this
    /// assertion breaks first.
    @Test("CacheCoordinatorConfig disables SSM re-derive for chat workflow")
    func cacheConfigDisablesSSMReDerive() throws {
        // Ownership moved from `ModelRuntime.buildCacheCoordinatorConfig`
        // (which now delegates to `VMLXServerRuntimeSettings.cacheCoordinatorConfig`)
        // to `ServerRuntimeSettingsStore.migratedFromLegacy`. The
        // migrated default still seeds `enableSSMReDerive: false` so
        // osaurus's mutating-system-prefix chat workload doesn't pay the
        // re-derive cost across turns.
        let store = try Self.source("Models/Configuration/ServerRuntimeSettingsStore.swift")

        #expect(
            store.contains("enableSSMReDerive: false"),
            "ServerRuntimeSettingsStore.migratedFromLegacy must seed enableSSMReDerive=false — osaurus's mutating-system-prefix chat workload doesn't amortize the cost across turns"
        )
    }

    @Test("Flexible model residency respects load-time memory budget")
    func flexibleModelResidencyEvictsBeforeOversizedLoads() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")

        #expect(runtime.contains("flexibleResidentBudgetBytes"))
        #expect(runtime.contains("ProcessInfo.processInfo.physicalMemory) * 0.70"))
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
    /// TokenIterator-backed fast path. Osaurus must not let a second same-model
    /// request run prompt tokenization / `MLXArray.asArray(...)` while that
    /// decode is still active. vmlx emits `.info` before its post-generation
    /// cache store finishes, so Osaurus also must not release the solo lease
    /// at `.info`; otherwise a second request can enter `prepareInput` while
    /// the first one is still materializing safetensors cache tensors on Metal.
    @Test("MLXBatchAdapter gates same-model solo generation and propagates stream cancellation")
    func mlxBatchAdapterGatesSoloGenerationAndCancelsProducer() throws {
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")

        #expect(adapter.contains("actor SoloGenerationGate"))
        #expect(adapter.contains("maxBatchSize == 1"))
        #expect(adapter.contains("acquireSoloLease"))
        #expect(adapter.contains("await soloLease.release()"))
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

    /// Preflight tool selection is a background prompt-ranking call, not the user's
    /// answer. It can fall back to the active chat model, so reasoning families
    /// must be forced onto their short non-thinking path or they can monopolize
    /// the single B=1 engine slot before the real chat request starts.
    @Test("Preflight fallback LLM forces no-think model options")
    func preflightFallbackLLMForcesNoThinkOptions() throws {
        let coreModel = try Self.source("Services/Inference/CoreModelService.swift")
        let preflight = try Self.source("Services/Context/PreflightCapabilitySearch.swift")

        #expect(
            coreModel.contains("modelOptions: [String: ModelOptionValue]"),
            "CoreModelService.generate must provide an internal per-call modelOptions path so background callers can choose non-thinking rails without exposing internal option types as public API"
        )
        #expect(
            coreModel.contains("modelOptions: modelOptions"),
            "CoreModelService.generate must thread modelOptions into GenerationParameters before routing to MLX/remote services"
        )
        #expect(
            preflight.contains("modelOptions: [\"reasoningEffort\": .string(\"no_think\")]"),
            "PreflightCapabilitySearch.defaultLLM must force no_think so Hy3/ZAYA/Qwen-style reasoning templates do not spend the tool-ranking timeout generating long reasoning traces"
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
        #expect(agentRun.contains("runToolBatchInParallel"))
        #expect(
            !agentRun.contains("StreamingToolHint.encode(")
                && !agentRun.contains("StreamingToolHint.encodeArgs")
                && !agentRun.contains("StreamingToolHint.encodeDone"),
            "/agents/{id}/run should execute tools server-side and stream only final assistant text, not internal U+FFFE tool sentinels."
        )
        #expect(agentRun.contains("assistantToolCalls.append"))
        #expect(agentRun.contains("ChatMessage(role: \"tool\""))
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
            runtime.contains("if let modelName, record.modelName != modelName { return }"),
            "ModelRuntime.unload(name:) must not cancel a generation belonging to a different model"
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

    @Test("ModelRuntime uses typed vmlx load configuration")
    func modelRuntimeUsesTypedVMLXLoadConfiguration() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")

        #expect(runtime.contains("loadConfiguration: mtpPlan.loadConfiguration"))
        #expect(runtime.contains("resolvedLoadConfiguration("))
        #expect(
            !runtime.contains(
                "loadModelContainer(\n                from: localURL,\n                using: tokenizerLoader\n            )"
            ),
            "ModelRuntime must not use the plain local-directory load overload; it bypasses vmlx LoadConfiguration.default, including load-time memory caps, mmap safetensors, and JANGTQ prestack/alignment"
        )
    }

    @Test("MTP bundles auto-resolve vmlx tuning into load and generation")
    func mtpBundlesAutoResolveVMLXTuningIntoLoadAndGeneration() throws {
        let runtime = try Self.source("Services/ModelRuntime.swift")
        let adapter = try Self.source("Services/ModelRuntime/MLXBatchAdapter.swift")

        #expect(runtime.contains("MTPBundleInspector.inspect("))
        #expect(runtime.contains("VMLXServerRuntimeSettings()"))
        #expect(runtime.contains("settings.mtp.mode = .auto"))
        #expect(runtime.contains("resolvedMTPLaunch("))
        #expect(runtime.contains("resolvedLoadConfiguration("))
        #expect(runtime.contains("resolvedMTPDraftStrategy("))
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
        #expect(httpHandler.contains("\"mlx_press\""))
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

    @Test("Chat UI sends accumulated history and keeps implicit native MTP sampling")
    func chatUISendsAccumulatedHistoryAndImplicitNativeMTPSampling() throws {
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
        #expect(
            chatView.contains(
                "if let msg = turnToMessage(t, isLastTurn: isLastTurn) {\n                            msgs.append(msg)\n                        }"
            ),
            "Every non-empty prior user/assistant/tool turn should be converted into ChatMessage history."
        )
        #expect(buildMessages.lowerBound < streamRequest.lowerBound)
        #expect(streamRequest.lowerBound < implicitSampling.lowerBound)
        #expect(
            chatView.contains("temperature: effectiveTemp"),
            "The UI may pass the agent/profile temperature, but it must also mark sampling implicit so native MTP can force greedy defaults."
        )
        #expect(
            chatView.contains("tools: toolSpecs.isEmpty ? nil : toolSpecs"),
            "Chat UI should only send tool schemas when the composer resolved a non-empty tool set."
        )
        #expect(
            chatView.contains("tool_choice: toolSpecs.isEmpty ? nil : .auto"),
            "Chat UI should keep the local no-tool path available by omitting auto tool choice when no tools are resolved."
        )
        #expect(
            chatView.contains("finalReq.samplingParametersAreImplicit = true"),
            "Tool-budget wrap-up calls use the same implicit-sampling contract as normal UI turns."
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

    @Test("Runtime docs keep upstream Metal fault boundaries explicit")
    func inferenceDocsKeepUpstreamMetalFaultBoundaries() throws {
        let runtimeDoc = try Self.source("../../docs/INFERENCE_RUNTIME.md")
        let lingDoc = try Self.source("../../docs/LING_JANGTQ2_LONG_PROMPT_CRASH.md")

        #expect(runtimeDoc.contains("BailingLinearAttention.recurrentGLA"))
        #expect(runtimeDoc.contains("enableSSMReDerive=false"))
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
}
