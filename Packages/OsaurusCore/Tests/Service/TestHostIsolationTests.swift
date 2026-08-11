//
//  TestHostIsolationTests.swift
//  OsaurusCore
//
//  Prove that test hosts use disposable data and never reach production keys.
//

import Foundation
import LocalAuthentication
import OsaurusRepository
import Security
import Testing

@testable import OsaurusCore

@Suite("Test-host isolation", .serialized)
struct TestHostIsolationTests {
    @Test("XCTest hosts disable real keychain access without a shell flag")
    func xctestHostUsesSharedKeychainDecision() {
        #expect(!KeychainQueryHelpers.realKeychainTestsAreExplicitlyEnabled)
        #expect(ProcessDataRootPolicy.isRecognizedTestHostProcess)
        #expect(KeychainQueryHelpers.usesInMemoryKeychainStoreForTests)
        #expect(KeychainQueryHelpers.disablesKeychainForProcess)
        #expect(KeychainQueryHelpers.disablesIdentityKeyForProcess)
        #expect(StorageKeyManager.disablesKeychainForProcess)
    }

    @Test("default test hosts short-circuit foreground and background MasterKey reads")
    func identityKeyReadsStopBeforeSecurityFramework() async {
        #expect(ProcessDataRootPolicy.isRecognizedTestHostProcess)
        #expect(KeychainQueryHelpers.disablesKeychainForProcess)

        // This is the same off-main path used by MasterKey's launch/cache work.
        // If the policy regresses, the await reaches SecItemCopyMatching and the
        // test host's execution timeout identifies this test instead of leaving
        // an anonymous pre-discovery task blocked in securityd.
        await MasterKey.seedExistsCacheOffMainActor()
        #expect(!MasterKey.existsCached())
        #expect(!MasterKey.exists())

        let context = LAContext()
        context.interactionNotAllowed = true
        do {
            _ = try MasterKey.getPrivateKey(context: context)
            Issue.record("Keychain-disabled test host unexpectedly read the Master Key")
        } catch let error as OsaurusIdentityError {
            guard case .keychainReadFailed = error else {
                Issue.record("Expected keychainReadFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected OsaurusIdentityError, got \(error)")
        }
        #expect(MasterKey.delete())
    }

    @Test("factory-reset service deletion is disabled before Security.framework")
    func factoryResetKeychainDeletionUsesCentralGate() throws {
        try #require(KeychainQueryHelpers.disablesKeychainForProcess)
        for service in OsaurusKeychainServices.all {
            #expect(Keychain.deleteAllItems(service: service) == .disabled)
        }

        let serviceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let coreRoot =
            serviceDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let onboardingSource = try String(
            contentsOf: coreRoot.appendingPathComponent("Services/OnboardingService.swift"),
            encoding: .utf8
        )
        #expect(onboardingSource.contains("Keychain.deleteAllItems(service: service)"))
        #expect(!onboardingSource.contains("SecItemDelete("))
    }

    @Test("OsaurusPaths resolves to the disposable test root at runtime")
    func osaurusPathsUsesDisposableRootBehaviorally() async {
        await StoragePathsTestLock.shared.run {
            let previousOverride = OsaurusPaths.overrideRoot
            OsaurusPaths.overrideRoot = nil
            defer { OsaurusPaths.overrideRoot = previousOverride }

            let productionRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".osaurus", isDirectory: true)
            let resolved = OsaurusPaths.root().standardizedFileURL

            #expect(resolved != productionRoot.standardizedFileURL)
            if let configuredRoot = ProcessInfo.processInfo.environment["OSAURUS_TEST_ROOT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !configuredRoot.isEmpty {
                let configuredURL = URL(
                    fileURLWithPath: configuredRoot,
                    isDirectory: true
                ).standardizedFileURL

                // Environment roots cross a process boundary and are accepted
                // only when the launcher already prepared a private directory.
                // Missing or unsafe paths must fall back to the process-owned
                // automatic root instead of touching production storage.
                #expect(
                    resolved == configuredURL || resolved.path.hasPrefix("/tmp/osa-t-")
                )
            } else {
                #expect(resolved.path.hasPrefix("/tmp/osa-t-"))
            }
        }
    }

    @Test("test-host model discovery ignores production bookmarks and home directories")
    func modelDirectoryUsesDisposableRootBehaviorally() async {
        await StoragePathsTestLock.shared.run {
            let previousOverride = OsaurusPaths.overrideRoot
            let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
                "osu-model-root-isolation-\(UUID().uuidString)",
                isDirectory: true
            )
            OsaurusPaths.overrideRoot = testRoot
            defer {
                OsaurusPaths.overrideRoot = previousOverride
                try? FileManager.default.removeItem(at: testRoot)
            }

            #expect(ProcessDataRootPolicy.isRecognizedTestHostProcess)
            #expect(
                DirectoryPickerService.effectiveModelsDirectory().standardizedFileURL
                    == testRoot.appendingPathComponent("MLXModels", isDirectory: true).standardizedFileURL
            )
        }
    }

    @Test("XCTest model-directory overrides require an explicit second opt-in")
    func modelDirectoryOverrideCannotBypassTestIsolationAccidentally() {
        let externalDirectory = "/Users/example/production-models"
        let baseEnvironment = ["OSU_MODELS_DIR": externalDirectory]

        #expect(
            DirectoryPickerService.modelsDirectoryEnvironmentOverride(
                environment: baseEnvironment,
                recognizedTestHost: true
            ) == nil
        )
        #expect(
            DirectoryPickerService.modelsDirectoryEnvironmentOverride(
                environment: baseEnvironment,
                recognizedTestHost: false
            )?.path == externalDirectory
        )

        var pendingHostEnvironment = baseEnvironment
        pendingHostEnvironment["XCTestConfigurationFilePath"] =
            "/tmp/pending.xctestconfiguration"
        #expect(
            DirectoryPickerService.modelsDirectoryEnvironmentOverride(
                environment: pendingHostEnvironment,
                recognizedTestHost: false
            ) == nil
        )

        var explicitlyAllowed = baseEnvironment
        explicitlyAllowed[
            DirectoryPickerService.allowExternalModelsInTestHostsEnvironmentKey
        ] = "1"
        #expect(
            DirectoryPickerService.modelsDirectoryEnvironmentOverride(
                environment: explicitlyAllowed,
                recognizedTestHost: true
            )?.path == externalDirectory
        )
        explicitlyAllowed["XCTestConfigurationFilePath"] =
            "/tmp/pending.xctestconfiguration"
        #expect(
            DirectoryPickerService.modelsDirectoryEnvironmentOverride(
                environment: explicitlyAllowed,
                recognizedTestHost: false
            )?.path == externalDirectory
        )

        // A non-XCTest live-proof launcher deliberately opts into its model
        // root with OSU_MODELS_DIR. Automatic bundle mutation remains disabled
        // by the shared isolation predicate.
        let liveProofEnvironment = [
            "OSU_MODELS_DIR": externalDirectory,
            ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "1",
        ]
        #expect(
            DirectoryPickerService.modelsDirectoryEnvironmentOverride(
                environment: liveProofEnvironment,
                recognizedTestHost: false
            )?.path == externalDirectory
        )
        #expect(
            !ModelManager.allowsAutomaticCatalogMutation(
                environment: liveProofEnvironment,
                recognizedTestHost: false
            )
        )
    }

    @Test("model discovery follows every shared process-isolation reason")
    func modelDirectoryIsolationUsesSharedPredicate() {
        let cases: [[String: String]] = [
            [ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "1"],
            [ProcessDataRootPolicy.testRootEnvironmentKey: "/tmp/isolated-model-root"],
            [ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey: "1"],
            [
                ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey:
                    "36CFBE8B-39DB-47DB-BA95-1742165D2657"
            ],
        ]

        for environment in cases {
            #expect(
                DirectoryPickerService.shouldUseIsolatedModelsDirectory(
                    environment: environment,
                    recognizedTestHost: false
                )
            )
        }
        #expect(
            DirectoryPickerService.shouldUseIsolatedModelsDirectory(
                environment: [:],
                recognizedTestHost: true
            )
        )
        #expect(
            !DirectoryPickerService.shouldUseIsolatedModelsDirectory(
                environment: [:],
                recognizedTestHost: false
            )
        )
    }

    @Test("test hosts do not launch unowned model catalog work")
    func modelManagerBackgroundCatalogWorkIsDisabled() {
        #expect(ProcessDataRootPolicy.isRecognizedTestHostProcess)
        #expect(!ModelManager.allowsAutomaticCatalogWorkForCurrentProcess)
        #expect(
            !ModelManager.allowsAutomaticCatalogWork(
                environment: [
                    "XCTestConfigurationFilePath": "/tmp/pending.xctestconfiguration"
                ],
                recognizedTestHost: false
            )
        )
        #expect(
            ModelManager.allowsAutomaticCatalogWork(
                environment: [
                    ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "1"
                ],
                recognizedTestHost: false
            ),
            "Explicit non-XCTest live proof keeps read-only catalog work available"
        )
    }

    @Test("isolated processes never schedule automatic model mutations")
    func modelManagerMutationGateUsesSharedIsolationPredicate() {
        #expect(
            !ModelManager.allowsAutomaticCatalogMutation(
                environment: [ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "1"],
                recognizedTestHost: false
            )
        )
        #expect(
            !ModelManager.allowsAutomaticCatalogMutation(
                environment: [ProcessDataRootPolicy.testRootEnvironmentKey: "/tmp/model-proof"],
                recognizedTestHost: false
            )
        )
        #expect(
            !ModelManager.allowsAutomaticCatalogMutation(
                environment: [:],
                recognizedTestHost: true
            )
        )
        #expect(
            !ModelManager.allowsAutomaticCatalogMutation(
                environment: ["OSU_MODELS_DIR": "/tmp/read-only-model-proof"],
                recognizedTestHost: false
            )
        )
        #expect(
            !ModelManager.allowsAutomaticAmbientCatalogDiscovery(
                environment: ["OSU_MODELS_DIR": "/tmp/read-only-model-proof"],
                recognizedTestHost: false
            )
        )
        #expect(
            ModelManager.allowsAutomaticCatalogMutation(
                environment: [:],
                recognizedTestHost: false
            )
        )
    }

    @Test("path and keychain helpers use the shared isolation policy")
    func sourceWiringUsesSharedPolicy() throws {
        let serviceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let coreRoot = serviceDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packagesRoot = coreRoot.deletingLastPathComponent()
        let repositoryRoot = packagesRoot
            .appendingPathComponent("OsaurusRepository", isDirectory: true)

        let keychainSource = try String(
            contentsOf: coreRoot
                .appendingPathComponent("Services/Keychain/KeychainQueryHelpers.swift"),
            encoding: .utf8
        )
        let storageKeySource = try String(
            contentsOf: coreRoot.appendingPathComponent("Identity/StorageKeyManager.swift"),
            encoding: .utf8
        )
        let identityKeySource = try String(
            contentsOf: coreRoot.appendingPathComponent("Identity/MasterKey.swift"),
            encoding: .utf8
        )
        let agentManagerSource = try String(
            contentsOf: coreRoot.appendingPathComponent("Managers/AgentManager.swift"),
            encoding: .utf8
        )
        let pathsSource = try String(
            contentsOf: coreRoot.appendingPathComponent("Utils/OsaurusPaths.swift"),
            encoding: .utf8
        )
        let toolsSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("ToolsPaths.swift"),
            encoding: .utf8
        )
        #expect(keychainSource.contains("ProcessDataRootPolicy.shouldDisableKeychain"))
        #expect(keychainSource.contains("ProcessDataRootPolicy.isRecognizedTestHostProcess"))
        #expect(storageKeySource.contains("ProcessDataRootPolicy.shouldDisableKeychain"))
        #expect(
            identityKeySource.contains(
                "if KeychainQueryHelpers.disablesIdentityKeyForProcess { return false }"
            )
        )
        #expect(
            identityKeySource.contains(
                "if KeychainQueryHelpers.disablesIdentityKeyForProcess {\n"
                    + "            throw OsaurusIdentityError.keychainReadFailed"
            )
        )
        #expect(agentManagerSource.contains("Task.detached(priority: .userInitiated)"))
        #expect(agentManagerSource.contains("guard MasterKey.exists() else { return }"))
        #expect(agentManagerSource.contains("MasterKey.getPrivateKey(context: context)"))
        #expect(pathsSource.contains("ProcessDataRootPolicy.resolvedRoot"))
        #expect(toolsSource.contains("ProcessDataRootPolicy.resolvedRoot"))

    }
}
