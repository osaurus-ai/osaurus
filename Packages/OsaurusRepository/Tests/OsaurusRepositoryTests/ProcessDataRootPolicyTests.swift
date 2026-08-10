//
//  ProcessDataRootPolicyTests.swift
//  OsaurusRepository
//
//  Policy and concurrency coverage for test-host secret/data isolation.
//

import Foundation
import XCTest

@testable import OsaurusRepository

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URL] = []

    func append(_ value: URL) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var allValues: [URL] {
        lock.lock()
        let snapshot = values
        lock.unlock()
        return snapshot
    }
}

/// Compiles the policy into a normal command-line executable so forged XCTest
/// environment values can be tested outside the XCTest process itself.
private final class PolicyProbe {
    private let root: URL
    private let executable: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-policy-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        let policyURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ProcessDataRootPolicy.swift")
            .standardizedFileURL
        guard FileManager.default.fileExists(atPath: policyURL.path) else {
            throw NSError(
                domain: "ProcessDataRootPolicyTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Policy source was not found at \(policyURL.path)"]
            )
        }

        let probeSource = root.appendingPathComponent("main.swift")
        try """
        import Foundation

        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "actual" {
            let recognized = ProcessDataRootPolicy.isRecognizedTestHostProcess
            let disabled = ProcessDataRootPolicy.shouldDisableKeychain(
                environment: ProcessInfo.processInfo.environment,
                recognizedTestHost: recognized
            )
            let root = ProcessDataRootPolicy.resolvedRoot(
                defaultRoot: URL(fileURLWithPath: "/Users/example/.osaurus", isDirectory: true)
            )
            print("recognized=\\(recognized)")
            print("keychainDisabled=\\(disabled)")
            print("root=\\(root.path)")
        } else if arguments.count >= 6 {
            let recognized = ProcessDataRootPolicy.isRecognizedTestHost(
                environment: ProcessInfo.processInfo.environment,
                processName: arguments[1],
                bundlePath: arguments[2],
                executablePath: arguments[3],
                arguments: [arguments[4]],
                loadedBundlePaths: [arguments[5]],
                testFrameworkLoaded: false
            )
            print("recognized=\\(recognized)")
        } else {
            print("invalid-probe-arguments")
        }
        """.write(to: probeSource, atomically: true, encoding: .utf8)

        executable = root.appendingPathComponent("policy-probe", isDirectory: false)
        let compiler = "/usr/bin/xcrun"
        guard FileManager.default.isExecutableFile(atPath: compiler) else {
            throw NSError(
                domain: "ProcessDataRootPolicyTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "xcrun is required for the runtime probe"]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: compiler)
        process.arguments = ["swiftc", policyURL.path, probeSource.path, "-o", executable.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let details = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "unknown compiler failure"
            throw NSError(
                domain: "ProcessDataRootPolicyTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: details]
            )
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func run(mode: String, environment overrides: [String: String], arguments: [String]) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        for key in [
            ProcessDataRootPolicy.testRootEnvironmentKey,
            ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey,
            ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey,
            ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey,
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "__XCTestBundleInjectPath",
            "XCTestSessionIdentifier",
        ] {
            environment.removeValue(forKey: key)
        }
        environment.merge(overrides) { _, new in new }

        let process = Process()
        process.executableURL = executable
        process.arguments = [mode] + arguments
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let rendered = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, rendered)
        return rendered
    }
}

final class ProcessDataRootPolicyTests: XCTestCase {
    func testRecognitionLatchReevaluatesFalseAndSticksTrue() {
        let latch = TestHostRecognitionLatch()
        var probes = 0

        XCTAssertFalse(latch.value {
            probes += 1
            return false
        })
        XCTAssertTrue(latch.value {
            probes += 1
            return true
        })
        XCTAssertTrue(latch.value {
            XCTFail("A confirmed test-host identity must not be re-probed")
            return false
        })
        XCTAssertEqual(probes, 2)
    }

    func testRecognizesCurrentTestRuntimeUsingCorroboratedIdentity() throws {
        let executablePath = try XCTUnwrap(Bundle.main.executablePath)
        let testFrameworkLoaded = NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil

        XCTAssertTrue(testFrameworkLoaded)
        XCTAssertTrue(ProcessDataRootPolicy.isRecognizedTestHostProcess)
        XCTAssertTrue(
            ProcessDataRootPolicy.isRecognizedTestHost(
                environment: ProcessInfo.processInfo.environment,
                processName: ProcessInfo.processInfo.processName,
                bundlePath: Bundle.main.bundlePath,
                executablePath: executablePath,
                loadedBundlePaths: Bundle.allBundles.map(\.bundlePath),
                testFrameworkLoaded: testFrameworkLoaded
            )
        )
    }

    func testForgedMarkersNamesAndPathsDoNotRecognizeAProductionIdentity() throws {
        let fakeBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("LooksLikeTests-\(UUID().uuidString).xctest", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fakeBundle) }
        try FileManager.default.createDirectory(at: fakeBundle, withIntermediateDirectories: false)

        let forgedEnvironment = [
            "XCTestConfigurationFilePath": "/tmp/forged.xctestconfiguration",
            "XCTestBundlePath": fakeBundle.path,
            "__XCTestBundleInjectPath": fakeBundle.path,
            "XCTestSessionIdentifier": UUID().uuidString,
        ]
        let productionBundle = "/Applications/Osaurus.app"
        let productionExecutable = "/Applications/Osaurus.app/Contents/MacOS/osaurus"

        XCTAssertFalse(
            ProcessDataRootPolicy.isRecognizedTestHost(
                environment: forgedEnvironment,
                processName: "osaurus",
                bundlePath: productionBundle,
                executablePath: productionExecutable,
                arguments: [fakeBundle.appendingPathComponent("Contents/MacOS/osaurus").path],
                loadedBundlePaths: [fakeBundle.path],
                testFrameworkLoaded: false
            )
        )
        XCTAssertFalse(
            ProcessDataRootPolicy.isRecognizedTestHost(
                environment: forgedEnvironment,
                processName: "xctest",
                bundlePath: productionBundle,
                executablePath: "/tmp/xctest",
                loadedBundlePaths: [],
                testFrameworkLoaded: false
            ),
            "A process basename cannot establish test-host identity"
        )
        XCTAssertFalse(
            ProcessDataRootPolicy.isRecognizedTestHost(
                environment: forgedEnvironment,
                processName: "swiftpm-testing-helper",
                bundlePath: productionBundle,
                executablePath: productionExecutable,
                loadedBundlePaths: [],
                testFrameworkLoaded: true
            ),
            "A forged SwiftPM helper name cannot establish test-host identity"
        )
        XCTAssertFalse(
            ProcessDataRootPolicy.isRecognizedTestHost(
                environment: [
                    "XCTestConfigurationFilePath": "/tmp/only-a-marker.xctestconfiguration"
                ],
                processName: "osaurus",
                bundlePath: productionBundle,
                executablePath: productionExecutable,
                testFrameworkLoaded: false
            ),
            "A single environment marker cannot establish test-host identity"
        )
    }

    func testSubprocessRejectsForgedRuntimeMarkersAndSyntheticIdentity() throws {
        let probe = try PolicyProbe()
        let forgedEnvironment = [
            "XCTestConfigurationFilePath": "/tmp/forged.xctestconfiguration",
            "XCTestBundlePath": "/tmp/Forged.xctest",
            "__XCTestBundleInjectPath": "/tmp/Forged.xctest",
            "XCTestSessionIdentifier": UUID().uuidString,
        ]

        let runtimeOutput = try probe.run(
            mode: "actual",
            environment: forgedEnvironment,
            arguments: []
        )
        XCTAssertTrue(runtimeOutput.contains("recognized=false"), runtimeOutput)
        XCTAssertTrue(runtimeOutput.contains("keychainDisabled=false"), runtimeOutput)
        XCTAssertTrue(runtimeOutput.contains("root=/Users/example/.osaurus"), runtimeOutput)

        let syntheticOutput = try probe.run(
            mode: "synthetic",
            environment: forgedEnvironment,
            arguments: [
                "xctest",
                "/tmp/Forged.xctest",
                "/tmp/xctest",
                "/tmp/Forged.xctest/Contents/MacOS/Forged",
                "",
            ]
        )
        XCTAssertTrue(syntheticOutput.contains("recognized=false"), syntheticOutput)
    }

    func testTestHostDoesNotEvaluatePersistentDefaultRoot() {
        var evaluated = false
        let persistentRoot = URL(fileURLWithPath: "/Users/example/.osaurus", isDirectory: true)
        let resolved = ProcessDataRootPolicy.resolvedRootForTesting(
            defaultRoot: recordDefaultRoot(&evaluated, root: persistentRoot),
            environment: [:],
            recognizedTestHost: true
        )

        XCTAssertFalse(evaluated)
        XCTAssertNotEqual(resolved.standardizedFileURL, persistentRoot.standardizedFileURL)
        XCTAssertTrue(resolved.standardizedFileURL.path.hasPrefix("/tmp/osa-t-"))

        let representativeSocket = resolved
            .appendingPathComponent("container", isDirectory: true)
            .appendingPathComponent("test-bridge.sock")
            .path
        XCTAssertLessThanOrEqual(representativeSocket.utf8.count, 103)
    }

    func testExplicitTestRootWinsWithoutEvaluatingProductionDefault() throws {
        var evaluated = false
        let testRoot = URL(
            fileURLWithPath: "/tmp/osaurus-test-root-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: testRoot) }
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: testRoot.path
        )
        let resolved = ProcessDataRootPolicy.resolvedRootForTesting(
            defaultRoot: recordDefaultRoot(
                &evaluated,
                root: URL(fileURLWithPath: "/Users/example/.osaurus", isDirectory: true)
            ),
            environment: ["OSAURUS_TEST_ROOT": testRoot.path],
            recognizedTestHost: true
        )

        XCTAssertFalse(evaluated)
        XCTAssertEqual(resolved.standardizedFileURL, testRoot.standardizedFileURL)
        XCTAssertTrue(
            ProcessDataRootPolicy.shouldDisableKeychain(
                environment: ["OSAURUS_TEST_ROOT": testRoot.path],
                recognizedTestHost: false
            )
        )
    }

    func testHomeOsaurusAndRelativeRootsFallBackToAutomaticPrivateRoot() {
        let homeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".osaurus", isDirectory: true)
        let productionRoot = URL(fileURLWithPath: "/Users/example/.osaurus", isDirectory: true)

        XCTAssertFalse(ProcessDataRootPolicy.isSafeIsolatedTestRoot(homeRoot))
        let homeResolved = ProcessDataRootPolicy.resolvedRootForTesting(
            overrideRoot: homeRoot,
            defaultRoot: productionRoot,
            environment: [:],
            recognizedTestHost: true
        )
        XCTAssertTrue(homeResolved.path.hasPrefix("/tmp/osa-t-"))

        let relativeResolved = ProcessDataRootPolicy.resolvedRootForTesting(
            defaultRoot: productionRoot,
            environment: [ProcessDataRootPolicy.testRootEnvironmentKey: "relative-root"],
            recognizedTestHost: true
        )
        XCTAssertTrue(relativeResolved.path.hasPrefix("/tmp/osa-t-"))
    }

    func testSafeTemporaryRootIsAcceptedForDocumentedTestFlow() throws {
        let root = URL(fileURLWithPath: "/tmp/osaurus-test-\(UUID().uuidString)", isDirectory: true)
        let productionRoot = URL(fileURLWithPath: "/Users/example/.osaurus", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        XCTAssertTrue(ProcessDataRootPolicy.isSafeIsolatedTestRoot(root))
        let resolved = ProcessDataRootPolicy.resolvedRootForTesting(
            defaultRoot: productionRoot,
            environment: [ProcessDataRootPolicy.testRootEnvironmentKey: root.path],
            recognizedTestHost: true
        )

        XCTAssertEqual(
            resolved,
            root.standardizedFileURL.resolvingSymlinksInPath()
        )
    }

    func testNonexistentExplicitRootFallsBackWithoutCreatingUncheckedPath() {
        let root = URL(
            fileURLWithPath: "/tmp/osaurus-missing-root-\(UUID().uuidString)",
            isDirectory: true
        )
        let resolved = ProcessDataRootPolicy.resolvedRootForTesting(
            defaultRoot: URL(fileURLWithPath: "/Users/example/.osaurus", isDirectory: true),
            environment: [ProcessDataRootPolicy.testRootEnvironmentKey: root.path],
            recognizedTestHost: true
        )

        XCTAssertFalse(ProcessDataRootPolicy.isSafeIsolatedTestRoot(root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(resolved.path.hasPrefix("/tmp/osa-t-"))
    }

    func testMissingProgrammaticOverrideIsCreatedPrivatelyForRecognizedTestHost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-programmatic-root-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        let resolved = ProcessDataRootPolicy.resolvedRootForTesting(
            overrideRoot: root,
            defaultRoot: URL(fileURLWithPath: "/Users/example/.osaurus", isDirectory: true),
            environment: [:],
            recognizedTestHost: true
        )

        XCTAssertEqual(resolved, root.standardizedFileURL.resolvingSymlinksInPath())
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o077, 0)
    }

    func testConcurrentMissingProgrammaticOverrideConvergesOnCreatedRoot() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-concurrent-programmatic-root-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let collector = URLCollector()

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            let resolved = ProcessDataRootPolicy.resolvedRootForTesting(
                overrideRoot: root,
                defaultRoot: URL(
                    fileURLWithPath: "/Users/example/.osaurus",
                    isDirectory: true
                ),
                environment: [:],
                recognizedTestHost: true
            )
            collector.append(resolved)
        }

        let roots = collector.allValues
        XCTAssertEqual(roots.count, 64)
        XCTAssertEqual(Set(roots.map(\.standardizedFileURL)), Set([root.standardizedFileURL]))
    }

    func testMissingProgrammaticOverrideIsNotCreatedWithoutRecognizedTestHost() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-unrecognized-root-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = ProcessDataRootPolicy.resolvedRootForTesting(
            overrideRoot: root,
            defaultRoot: URL(fileURLWithPath: "/Users/example/.osaurus", isDirectory: true),
            environment: [ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "1"],
            recognizedTestHost: false
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertTrue(resolved.path.hasPrefix("/tmp/osa-t-"))
    }

    func testExistingOwnedIsolatedRootIsTightenedToPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-policy-permissive-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)

        XCTAssertTrue(ProcessDataRootPolicy.isSafeIsolatedTestRoot(root))
        let resolved = ProcessDataRootPolicy.resolvedRootForTesting(
            overrideRoot: root,
            defaultRoot: URL(fileURLWithPath: "/Users/example/.osaurus", isDirectory: true),
            environment: [:],
            recognizedTestHost: true
        )
        XCTAssertEqual(resolved, root.standardizedFileURL.resolvingSymlinksInPath())
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o077, 0)
    }

    func testSymlinkEscapeIntoProductionIsRejected() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-policy-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)

        let link = parent.appendingPathComponent("escaped", isDirectory: true)
        let productionRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".osaurus", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: productionRoot)

        XCTAssertFalse(ProcessDataRootPolicy.isSafeIsolatedTestRoot(link))
        let resolved = ProcessDataRootPolicy.resolvedRootForTesting(
            overrideRoot: link,
            defaultRoot: URL(fileURLWithPath: "/Users/example/.osaurus", isDirectory: true),
            environment: [:],
            recognizedTestHost: true
        )
        XCTAssertTrue(resolved.path.hasPrefix("/tmp/osa-t-"))
    }

    func testSymlinkRootInsideTemporaryBoundaryIsRejected() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-policy-safe-symlink-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)

        let target = parent.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        let link = parent.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertFalse(ProcessDataRootPolicy.isSafeIsolatedTestRoot(link))
        let resolved = ProcessDataRootPolicy.resolvedRootForTesting(
            overrideRoot: link,
            defaultRoot: URL(fileURLWithPath: "/Users/example/.osaurus", isDirectory: true),
            environment: [:],
            recognizedTestHost: true
        )
        XCTAssertTrue(resolved.path.hasPrefix("/tmp/osa-t-"))
    }

    func testPrivateOverrideRootIsAccepted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "osaurus-policy-override-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)

        let resolved = ProcessDataRootPolicy.resolvedRootForTesting(
            overrideRoot: root,
            defaultRoot: URL(fileURLWithPath: "/Users/example/.osaurus", isDirectory: true),
            environment: [:],
            recognizedTestHost: true
        )

        XCTAssertEqual(resolved, root.standardizedFileURL.resolvingSymlinksInPath())
    }

    func testKeychainDisabledFlagAlsoSelectsDisposableRoot() {
        let persistentRoot = URL(fileURLWithPath: "/Users/example/.osaurus", isDirectory: true)
        let resolved = ProcessDataRootPolicy.resolvedRootForTesting(
            defaultRoot: persistentRoot,
            environment: ["OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS": "1"],
            recognizedTestHost: false
        )

        XCTAssertNotEqual(resolved.standardizedFileURL, persistentRoot.standardizedFileURL)
        XCTAssertTrue(
            ProcessDataRootPolicy.shouldDisableKeychain(
                environment: ["OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS": "1"],
                recognizedTestHost: false
            )
        )
    }

    func testRecognizedTestHostDisablesKeychainByDefault() {
        XCTAssertTrue(
            ProcessDataRootPolicy.shouldDisableKeychain(
                environment: [:],
                recognizedTestHost: true
            )
        )
    }

    func testChildIsolationCanonicalizesParentRootAndRejectsOverlayReplacement() throws {
        let parentRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-parent-root-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parentRoot) }
        try FileManager.default.createDirectory(at: parentRoot, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parentRoot.path)

        let parentEnvironment = [
            ProcessDataRootPolicy.testRootEnvironmentKey: "  \(parentRoot.path)  ",
            ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "1",
            "PARENT_SECRET": "must-not-be-inherited",
        ]
        let requestedEnvironment = [
            "TOOL_SETTING": "retained",
            ProcessDataRootPolicy.testRootEnvironmentKey: "/tmp/provider-root",
            ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "0",
            ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey: "1",
            ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey:
                "36CFBE8B-39DB-47DB-BA95-1742165D2657",
        ]

        let childEnvironment = ProcessDataRootPolicy.applyingChildTestIsolation(
            to: requestedEnvironment,
            parentEnvironment: parentEnvironment,
            parentRecognizedTestHost: false
        )

        XCTAssertEqual(
            childEnvironment[ProcessDataRootPolicy.testRootEnvironmentKey],
            parentRoot.standardizedFileURL.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(
            childEnvironment[ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey],
            "1"
        )
        XCTAssertEqual(childEnvironment["TOOL_SETTING"], "retained")
        XCTAssertNil(childEnvironment["PARENT_SECRET"])
        XCTAssertNil(childEnvironment[ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey])
        XCTAssertNil(
            childEnvironment[ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey]
        )
    }

    func testUnsafeChildRootsFallBackToThePrivateAutomaticRoot() throws {
        let symlinkParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("osaurus-child-root-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: symlinkParent) }
        try FileManager.default.createDirectory(at: symlinkParent, withIntermediateDirectories: false)
        let link = symlinkParent.appendingPathComponent("root", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".osaurus", isDirectory: true)
        )

        for rawRoot in [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                ".osaurus", isDirectory: true
            ).path,
            link.path,
            "/tmp/osaurus-future-child-root-\(UUID().uuidString)",
            "relative-root",
            "/tmp/../Users/example/.osaurus",
        ] {
            let childEnvironment = ProcessDataRootPolicy.applyingChildTestIsolation(
                to: ["TOOL_SETTING": "retained"],
                parentEnvironment: [
                    ProcessDataRootPolicy.testRootEnvironmentKey: rawRoot
                ],
                parentRecognizedTestHost: false
            )

            XCTAssertTrue(
                childEnvironment[ProcessDataRootPolicy.testRootEnvironmentKey]?
                    .hasPrefix("/tmp/osa-t-") == true,
                rawRoot
            )
            XCTAssertEqual(
                childEnvironment[ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey],
                "1",
                rawRoot
            )
        }
    }

    func testProviderCannotEnableIsolationMarkersForAProductionChild() {
        let childEnvironment = ProcessDataRootPolicy.applyingChildTestIsolation(
            to: [
                "TOOL_SETTING": "retained",
                ProcessDataRootPolicy.testRootEnvironmentKey: "/tmp/provider-root",
                ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "1",
                ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey: "1",
            ],
            parentEnvironment: ["PARENT_SECRET": "must-not-be-inherited"],
            parentRecognizedTestHost: false
        )

        XCTAssertEqual(childEnvironment["TOOL_SETTING"], "retained")
        XCTAssertNil(childEnvironment[ProcessDataRootPolicy.testRootEnvironmentKey])
        XCTAssertNil(
            childEnvironment[ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey]
        )
        XCTAssertNil(childEnvironment[ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey])
    }

    func testRecognizedTestHostChildGetsPrivateRootAndDisableMarker() {
        let childEnvironment = ProcessDataRootPolicy.applyingChildTestIsolation(
            to: ["TOOL_SETTING": "retained"],
            parentEnvironment: ["PARENT_SECRET": "must-not-be-inherited"],
            parentRecognizedTestHost: true
        )

        XCTAssertEqual(
            childEnvironment[ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey],
            "1"
        )
        XCTAssertTrue(
            childEnvironment[ProcessDataRootPolicy.testRootEnvironmentKey]?
                .hasPrefix("/tmp/osa-t-") == true
        )
        XCTAssertNil(childEnvironment["PARENT_SECRET"])
    }

    func testRealKeychainOptInLeavesGeneralKeychainIsolationEnabled() {
        let environment = [
            ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey: "1",
            ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey:
                "36CFBE8B-39DB-47DB-BA95-1742165D2657",
            "OSAURUS_TEST_ROOT": "/tmp/osaurus-real-keychain-proof",
        ]

        XCTAssertTrue(
            ProcessDataRootPolicy.explicitlyAllowsRealKeychainForTests(
                environment: environment
            )
        )
        XCTAssertTrue(
            ProcessDataRootPolicy.shouldDisableKeychain(
                environment: environment,
                recognizedTestHost: true
            )
        )
        XCTAssertEqual(
            ProcessDataRootPolicy.realKeychainTestNamespace(
                environment: environment,
                recognizedTestHost: true
            ),
            "36cfbe8b-39db-47db-ba95-1742165d2657"
        )
    }

    func testExplicitDisableWinsOverRealKeychainOptIn() {
        let environment = [
            "OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS": "1",
            ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey: "1",
            ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey:
                "36CFBE8B-39DB-47DB-BA95-1742165D2657",
        ]
        XCTAssertTrue(
            ProcessDataRootPolicy.shouldDisableKeychain(
                environment: environment,
                recognizedTestHost: true
            )
        )
        XCTAssertNil(
            ProcessDataRootPolicy.realKeychainTestNamespace(
                environment: environment,
                recognizedTestHost: true
            )
        )
    }

    func testRealKeychainOptInCannotBypassIsolationOutsideATestHost() {
        let environment = [
            ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey: "1",
            ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey:
                "36CFBE8B-39DB-47DB-BA95-1742165D2657",
        ]
        XCTAssertTrue(
            ProcessDataRootPolicy.shouldDisableKeychain(
                environment: environment,
                recognizedTestHost: false
            )
        )
        XCTAssertNil(
            ProcessDataRootPolicy.realKeychainTestNamespace(
                environment: environment,
                recognizedTestHost: false
            )
        )
    }

    func testAnyRealKeychainProofMarkerFailsClosedOutsideATestHost() {
        let proofEnvironments = [
            [ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey: "1"],
            [ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey: "invalid"],
            [
                ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey:
                    "36CFBE8B-39DB-47DB-BA95-1742165D2657"
            ],
            [ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey: "not-a-uuid"],
            [
                ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey: "1",
                ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey: "not-a-uuid",
            ],
        ]

        for environment in proofEnvironments {
            XCTAssertTrue(
                ProcessDataRootPolicy.shouldDisableKeychain(
                    environment: environment,
                    recognizedTestHost: false
                )
            )

            var evaluatedProductionRoot = false
            let productionRoot = URL(
                fileURLWithPath: "/Users/example/.osaurus",
                isDirectory: true
            )
            let root = ProcessDataRootPolicy.resolvedRootForTesting(
                defaultRoot: recordDefaultRoot(
                    &evaluatedProductionRoot,
                    root: productionRoot
                ),
                environment: environment,
                recognizedTestHost: false
            )
            XCTAssertFalse(evaluatedProductionRoot, "\(environment)")
            XCTAssertNotEqual(root.standardizedFileURL, productionRoot.standardizedFileURL)
            XCTAssertTrue(root.path.hasPrefix("/tmp/osa-t-"), "\(environment)")
        }
    }

    func testProofMarkersCannotBeStrippedIntoAProductionChild() {
        let proofEnvironments = [
            [ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey: "1"],
            [
                ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey:
                    "36CFBE8B-39DB-47DB-BA95-1742165D2657"
            ],
        ]

        for parentEnvironment in proofEnvironments {
            let childEnvironment = ProcessDataRootPolicy.applyingChildTestIsolation(
                to: [
                    ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey: "0",
                    ProcessDataRootPolicy.testRootEnvironmentKey: "/tmp/provider-root",
                ],
                parentEnvironment: parentEnvironment,
                parentRecognizedTestHost: false
            )

            XCTAssertEqual(
                childEnvironment[ProcessDataRootPolicy.disableKeychainForTestsEnvironmentKey],
                "1"
            )
            XCTAssertTrue(
                childEnvironment[ProcessDataRootPolicy.testRootEnvironmentKey]?
                    .hasPrefix("/tmp/osa-t-") == true
            )
            XCTAssertNil(
                childEnvironment[ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey]
            )
            XCTAssertNil(
                childEnvironment[
                    ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey
                ]
            )
        }
    }

    func testRealKeychainOptInRequiresAValidPerRunNamespace() {
        for namespace in [nil, "", "shared-production-name", "not-a-uuid"] {
            var environment = [
                ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey: "1",
                "OSAURUS_TEST_ROOT": "/tmp/osaurus-real-keychain-proof",
            ]
            environment[ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey] = namespace

            XCTAssertTrue(
                ProcessDataRootPolicy.shouldDisableKeychain(
                    environment: environment,
                    recognizedTestHost: true
                )
            )
            XCTAssertNil(
                ProcessDataRootPolicy.realKeychainTestNamespace(
                    environment: environment,
                    recognizedTestHost: true
                )
            )
        }
    }

    func testRealKeychainOptInRemainsRequestedBeforeNamespaceValidation() {
        let environment = [
            ProcessDataRootPolicy.allowRealKeychainForTestsEnvironmentKey: "1",
            ProcessDataRootPolicy.realKeychainTestNamespaceEnvironmentKey: "not-a-uuid",
        ]

        XCTAssertTrue(
            ProcessDataRootPolicy.explicitlyAllowsRealKeychainForTests(
                environment: environment
            )
        )
        XCTAssertNil(
            ProcessDataRootPolicy.realKeychainTestNamespace(
                environment: environment,
                recognizedTestHost: true
            )
        )
    }

    func testAutomaticRootIsStableAcrossConcurrentResolution() {
        let collector = URLCollector()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            let root = ProcessDataRootPolicy.resolvedRootForTesting(
                defaultRoot: URL(fileURLWithPath: "/Users/example/.osaurus", isDirectory: true),
                environment: [:],
                recognizedTestHost: true
            )
            collector.append(root)
        }

        let roots = collector.allValues
        XCTAssertEqual(roots.count, 64)
        XCTAssertEqual(Set(roots.map(\.standardizedFileURL)).count, 1)
    }

    func testAutomaticRootIsPrivateAndToolsPathsUsesItBehaviorally() throws {
        let previousOverride = ToolsPaths.overrideRoot
        ToolsPaths.overrideRoot = nil
        defer { ToolsPaths.overrideRoot = previousOverride }

        let productionRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".osaurus", isDirectory: true)
        let environment = ProcessInfo.processInfo.environment
        let expected = ProcessDataRootPolicy.resolvedRootForTesting(
            defaultRoot: productionRoot,
            environment: environment,
            recognizedTestHost: true
        )
        let toolsRoot = ToolsPaths.root()

        XCTAssertEqual(toolsRoot.standardizedFileURL, expected.standardizedFileURL)
        XCTAssertNotEqual(toolsRoot.standardizedFileURL, productionRoot.standardizedFileURL)
        if let configuredRoot = environment["OSAURUS_TEST_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configuredRoot.isEmpty {
            let configuredURL = URL(
                fileURLWithPath: configuredRoot,
                isDirectory: true
            ).standardizedFileURL
            if expected.standardizedFileURL == configuredURL {
                XCTAssertEqual(toolsRoot.standardizedFileURL, configuredURL)
            } else {
                XCTAssertTrue(toolsRoot.path.hasPrefix("/tmp/osa-t-"))
            }
        } else {
            XCTAssertTrue(toolsRoot.path.hasPrefix("/tmp/osa-t-"))
        }

        var isDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: toolsRoot.path, isDirectory: &isDirectory)
        )
        XCTAssertTrue(isDirectory.boolValue)
        let attributes = try FileManager.default.attributesOfItem(atPath: toolsRoot.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o077, 0)
    }

    func testProductionResolutionUsesDefaultRoot() {
        let productionRoot = URL(fileURLWithPath: "/Users/example/.osaurus", isDirectory: true)
        let resolved = ProcessDataRootPolicy.resolvedRootForTesting(
            defaultRoot: productionRoot,
            environment: [:],
            recognizedTestHost: false
        )

        XCTAssertEqual(resolved.standardizedFileURL, productionRoot.standardizedFileURL)
    }

    private func recordDefaultRoot(_ evaluated: inout Bool, root: URL) -> URL {
        evaluated = true
        return root
    }
}
