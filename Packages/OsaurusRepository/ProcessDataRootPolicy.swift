//
//  ProcessDataRootPolicy.swift
//  OsaurusRepository
//
//  Shared process-isolation policy for secret and filesystem-backed storage.
//

import Darwin
import Foundation

nonisolated(unsafe) private var automaticTestRootForCleanup: URL?

private func removeAutomaticTestRootAtExit() {
    guard let root = automaticTestRootForCleanup else { return }
    try? FileManager.default.removeItem(at: root)
}

/// Keeps test-host secrets and data out of the user's persistent stores.
///
/// The policy is intentionally narrow: it only changes resolution for an
/// explicit test flag, an explicit test root, or a process with XCTest host
/// identity signals. Ordinary app launches continue to use their configured
/// production root.
///
/// Explicit roots are trusted test-launcher inputs. The validation below
/// rejects unsafe locations, foreign ownership, permissive modes, and roots
/// that are already symlinks; it is not a security boundary against another
/// process running as the same user replacing a pathname after validation.
public enum ProcessDataRootPolicy {
    public static let testRootEnvironmentKey = "OSAURUS_TEST_ROOT"
    public static let disableKeychainForTestsEnvironmentKey =
        "OSAURUS_DISABLE_KEYCHAIN_FOR_TESTS"

    /// Deliberate opt-in used only by the separately filtered real-Keychain
    /// proof lane. Ordinary test hosts never set this variable.
    public static let allowRealKeychainForTestsEnvironmentKey =
        "OSAURUS_ALLOW_REAL_KEYCHAIN_FOR_TESTS"
    public static let realKeychainTestNamespaceEnvironmentKey =
        "OSAURUS_REAL_KEYCHAIN_TEST_NAMESPACE"

    /// These keys are reserved by the process-isolation policy. Child
    /// environments may retain ordinary caller configuration, but overlays
    /// must never be able to invent or replace these values.
    private static let childIsolationEnvironmentKeys = [
        testRootEnvironmentKey,
        disableKeychainForTestsEnvironmentKey,
        allowRealKeychainForTestsEnvironmentKey,
        realKeychainTestNamespaceEnvironmentKey,
    ]

    // Sandbox bridge sockets are nested below the data root and macOS limits
    // Unix-domain socket paths to roughly 104 bytes. Keep the automatic root
    // deliberately short instead of inheriting the much longer per-user
    // temporary-directory prefix under /var/folders.
    private static let automaticTestRoot: URL = {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "osa-t-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(12))",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            // Apply the mode explicitly as well as at creation so the contract
            // does not depend on the launching shell's umask.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.path
            )
            let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
            guard let permissions = attributes[.posixPermissions] as? NSNumber,
                permissions.intValue & 0o077 == 0
            else {
                throw CocoaError(.fileWriteNoPermission)
            }
        } catch {
            fatalError("Unable to create private Osaurus test root: \(error)")
        }
        automaticTestRootForCleanup = root
        atexit(removeAutomaticTestRootAtExit)
        return root
    }()

    /// True when the current process is an XCTest host or a SwiftPM test
    /// helper. Xcode does not reliably forward arbitrary shell environment
    /// variables into the launched test host, so process identity is the
    /// fallback that keeps the keychain and data-root decisions aligned.
    public static let isRecognizedTestHostProcess: Bool = {
        isRecognizedTestHost(
            environment: ProcessInfo.processInfo.environment,
            processName: ProcessInfo.processInfo.processName,
            bundlePath: Bundle.main.bundlePath,
            executablePath: Bundle.main.executablePath ?? CommandLine.arguments.first ?? "",
            arguments: CommandLine.arguments,
            loadedBundlePaths: Bundle.allBundles.map(\.bundlePath),
            testFrameworkLoaded: isXCTestRuntimeLoaded()
        )
    }()

    /// Pure host-recognition seam used by policy tests.
    public static func isRecognizedTestHost(
        environment: [String: String],
        processName: String,
        bundlePath: String,
        executablePath: String = "",
        arguments: [String] = [],
        loadedBundlePaths: [String] = [],
        testFrameworkLoaded: Bool = false
    ) -> Bool {
        // Environment values and argv are caller-controlled metadata. They
        // may corroborate a real test launch, but neither can establish one.
        _ = environment
        _ = arguments

        let normalizedProcessName = processName.lowercased()
        let mainTestBundle = existingXCTestBundleURL(for: bundlePath)
        let executableURL = existingExecutableURL(for: executablePath)
        let executableTestBundle = existingXCTestBundleURL(for: executablePath)
        let loadedTestBundles = loadedBundlePaths.compactMap(existingXCTestBundleURL(for:))
        let hasLoadedTestBundle = !loadedTestBundles.isEmpty

        // A test bundle is strong evidence only when the process executable
        // is the executable declared by that real bundle. This rejects an
        // Osaurus process whose argv or environment merely mentions `.xctest`.
        let executableBelongsToTestBundle = executableURL != nil
            && (executableTestBundle.map {
                testBundleExecutableURL(for: $0) == executableURL
            } ?? false)
        let mainBundleOwnsExecutable = mainTestBundle.map {
            executableURL != nil && testBundleExecutableURL(for: $0) == executableURL
        } ?? false
        let isTestBundleProcess = executableBelongsToTestBundle || mainBundleOwnsExecutable

        // Xcode can run a test bundle inside an application host, while
        // SwiftPM can use a helper executable. In both cases require an
        // actual loaded test bundle and the XCTest runtime, rather than
        // trusting the corresponding environment marker or basename.
        let isXCTestRunner = normalizedProcessName == "xctest"
            && executableURL?.lastPathComponent.lowercased() == "xctest"
            && isXCTestToolPath(executableURL)
        let isSwiftPMHelper = ["swiftpm-testing-helper", "swift-testing-helper"]
            .contains(normalizedProcessName)
            && executableURL?.lastPathComponent.lowercased() == normalizedProcessName

        return isTestBundleProcess
            || (testFrameworkLoaded && hasLoadedTestBundle)
            || (isXCTestRunner && hasLoadedTestBundle)
            || (isSwiftPMHelper && testFrameworkLoaded)
    }

    /// Keychain callers use this same decision as filesystem callers. A
    /// keychain-disabled process must not silently pair ephemeral secrets with
    /// a persistent data root.
    public static func shouldDisableKeychain(
        environment: [String: String],
        recognizedTestHost: Bool
    ) -> Bool {
        if environment[disableKeychainForTestsEnvironmentKey] == "1" {
            return true
        }
        // Proof markers are privileged test-only inputs. If they leak into a
        // production process, keep every Keychain wrapper disabled: namespace
        // validation below will reject the process, and falling back to the
        // production identity slot would turn a setup mistake into data loss.
        if explicitlyAllowsRealKeychainForTests(environment: environment)
            || hasValue(environment[realKeychainTestNamespaceEnvironmentKey]) {
            return true
        }
        return hasValue(environment[testRootEnvironmentKey]) || recognizedTestHost
    }

    /// Pure opt-in check shared by Core's Keychain wrappers and proof tests.
    public static func explicitlyAllowsRealKeychainForTests(
        environment: [String: String]
    ) -> Bool {
        environment[allowRealKeychainForTestsEnvironmentKey] == "1"
    }

    /// Returns a canonical per-run namespace only for an explicitly opted-in
    /// test host. Requiring both host recognition and a UUID keeps test code
    /// away from Osaurus's production Keychain service/account pair.
    public static func realKeychainTestNamespace(
        environment: [String: String],
        recognizedTestHost: Bool
    ) -> String? {
        guard recognizedTestHost,
            environment[disableKeychainForTestsEnvironmentKey] != "1",
            explicitlyAllowsRealKeychainForTests(environment: environment),
            let rawNamespace = environment[realKeychainTestNamespaceEnvironmentKey],
            let namespace = UUID(uuidString: rawNamespace)
        else { return nil }
        return namespace.uuidString.lowercased()
    }

    /// Applies the narrow test-isolation contract to a child environment.
    ///
    /// The caller chooses the child's ordinary environment. Reserved Osaurus
    /// keys are removed from that environment first, then only the parent's
    /// explicit disposable-root and keychain-disable markers are restored, so
    /// a provider or tool cannot replace the policy. Real-Keychain proof
    /// opt-in is never forwarded to a child process.
    public static func applyingChildTestIsolation(
        to environment: [String: String],
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        parentRecognizedTestHost: Bool = isRecognizedTestHostProcess
    ) -> [String: String] {
        var childEnvironment = environment
        for key in childIsolationEnvironmentKeys {
            childEnvironment.removeValue(forKey: key)
        }

        let parentRequiresIsolation = shouldDisableKeychain(
            environment: parentEnvironment,
            recognizedTestHost: parentRecognizedTestHost
        )

        if let rawRoot = parentEnvironment[testRootEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawRoot.isEmpty {
            if let root = canonicalChildTestRoot(rawRoot) {
                childEnvironment[testRootEnvironmentKey] = root.path
            } else {
                // An unsafe parent marker must never be forwarded verbatim.
                // Use the already-created private root and keep Keychain
                // disabled so a bad overlay cannot restore production state.
                childEnvironment[testRootEnvironmentKey] = automaticTestRoot.path
                childEnvironment[disableKeychainForTestsEnvironmentKey] = "1"
            }
        }

        // Every reason that isolates the parent must isolate the child too,
        // including malformed/leaked real-Keychain proof markers. Forward an
        // already-created private root so the child cannot fall back to the
        // user's home directory before its own resolver initializes.
        if parentRequiresIsolation {
            if !hasValue(childEnvironment[testRootEnvironmentKey]) {
                childEnvironment[testRootEnvironmentKey] = automaticTestRoot.path
            }
            childEnvironment[disableKeychainForTestsEnvironmentKey] = "1"
        }
        return childEnvironment
    }

    /// Resolves a data root without evaluating the production default in an
    /// isolated process. `defaultRoot` is autoclosure-backed because the Core
    /// default performs legacy migration as part of initialization.
    public static func resolvedRoot(
        overrideRoot: URL? = nil,
        defaultRoot: @autoclosure () -> URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        resolveRoot(
            overrideRoot: overrideRoot,
            defaultRoot: defaultRoot,
            environment: environment,
            recognizedTestHost: isRecognizedTestHostProcess
        )
    }

    /// Deterministic seam for testing the policy without changing process
    /// globals or evaluating a persistent default root.
    static func resolvedRootForTesting(
        overrideRoot: URL? = nil,
        defaultRoot: @autoclosure () -> URL,
        environment: [String: String],
        recognizedTestHost: Bool
    ) -> URL {
        resolveRoot(
            overrideRoot: overrideRoot,
            defaultRoot: defaultRoot,
            environment: environment,
            recognizedTestHost: recognizedTestHost
        )
    }

    /// Test-only seam for checking the filesystem contract without changing
    /// process-wide root overrides.
    static func isSafeIsolatedTestRoot(_ root: URL) -> Bool {
        safeIsolatedTestRootURL(root) != nil
    }

    private static func resolveRoot(
        overrideRoot: URL?,
        defaultRoot: () -> URL,
        environment: [String: String],
        recognizedTestHost: Bool
    ) -> URL {
        let isolatedTestProcess = recognizedTestHost
            || environment[disableKeychainForTestsEnvironmentKey] == "1"
            || hasValue(environment[testRootEnvironmentKey])

        // Preserve the production resolver exactly when no test isolation is
        // active. This includes callers that intentionally supply an override.
        guard isolatedTestProcess else {
            if let overrideRoot {
                return overrideRoot
            }
            if let configuredRoot = environment[testRootEnvironmentKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !configuredRoot.isEmpty {
                return URL(fileURLWithPath: configuredRoot, isDirectory: true)
            }
            return defaultRoot()
        }

        // An invalid explicit override must not fall through to another
        // caller-provided path. A recognized in-process test host may prepare
        // its own future temporary root atomically; environment and child
        // process roots remain existing-directory-only below.
        if let overrideRoot {
            if let safeRoot = safeIsolatedTestRootURL(overrideRoot) {
                return safeRoot
            }
            if recognizedTestHost,
                let preparedRoot = prepareProgrammaticTestOverrideRoot(overrideRoot) {
                return preparedRoot
            }
            return automaticTestRoot
        }
        if let configuredRoot = environment[testRootEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !configuredRoot.isEmpty {
            let root = URL(fileURLWithPath: configuredRoot, isDirectory: true)
            return safeIsolatedTestRootURL(root) ?? automaticTestRoot
        }
        return automaticTestRoot
    }

    /// Atomically creates a missing root supplied through the in-process test
    /// override seam. Existing tests set `OsaurusPaths.overrideRoot` before
    /// their fixture directory exists; collapsing those independent fixtures
    /// onto `automaticTestRoot` makes unrelated suites share state.
    ///
    /// This helper is deliberately not used for environment or child-process
    /// roots. Those paths cross a process boundary and must be created and
    /// validated by the launcher before they are accepted.
    private static func prepareProgrammaticTestOverrideRoot(_ root: URL) -> URL? {
        guard root.isFileURL, root.path.hasPrefix("/") else { return nil }

        let standardizedRoot = root.standardizedFileURL
        let name = standardizedRoot.lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        // Resolve the existing parent first, then create only its final child.
        // `mkdir` is atomic: a pre-existing file or symlink makes it fail.
        let parent = standardizedRoot.deletingLastPathComponent().resolvingSymlinksInPath()
        let candidate = parent.appendingPathComponent(name, isDirectory: true)
        guard safeTemporaryRoots().contains(where: {
            isPathStrictlyInside(candidate, boundary: $0)
        }) else {
            return nil
        }

        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: parent.path,
            isDirectory: &parentIsDirectory
        ), parentIsDirectory.boolValue else {
            return nil
        }

        var existingInfo = stat()
        guard lstat(candidate.path, &existingInfo) != 0, errno == ENOENT else {
            return nil
        }
        guard mkdir(candidate.path, mode_t(S_IRWXU)) == 0 else { return nil }

        var accepted = false
        defer {
            if !accepted {
                try? FileManager.default.removeItem(at: candidate)
            }
        }
        guard let safeRoot = safeIsolatedTestRootURL(candidate) else { return nil }
        accepted = true
        return safeRoot
    }

    private static func safeIsolatedTestRootURL(_ root: URL) -> URL? {
        guard root.isFileURL, root.path.hasPrefix("/") else { return nil }

        // Resolve `/tmp` and other parent aliases, but never accept a
        // caller-controlled symlink as the root itself. This rejects static
        // path escapes; trusted launchers still own the pathname-lifetime
        // contract documented on `ProcessDataRootPolicy` above.
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0,
            rootInfo.st_mode & S_IFMT != S_IFLNK
        else {
            return nil
        }

        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let safeRoots = safeTemporaryRoots()
        guard safeRoots.contains(where: {
            isPathStrictlyInside(canonicalRoot, boundary: $0)
        }) else {
            return nil
        }

        var isDirectory: ObjCBool = false
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                ensurePrivatePermissions(atPath: canonicalRoot.path, fileManager: fileManager)
            else {
                return nil
            }
            return canonicalRoot
        }

        // Do not return an unchecked future path. A symlink could replace a
        // non-existent root between policy resolution and later directory
        // creation. Test launchers must create their private root first.
        return nil
    }

    /// Child launchers may only forward a root the parent already created and
    /// validated. Accepting a future pathname would leave a window where a
    /// same-UID process could install a symlink before the child resolves it.
    private static func canonicalChildTestRoot(_ rawRoot: String) -> URL? {
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
        return safeIsolatedTestRootURL(root)
    }

    private static func existingExecutableURL(for path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url.resolvingSymlinksInPath()
    }

    private static func existingXCTestBundleURL(for path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        var candidate = URL(fileURLWithPath: path).standardizedFileURL
        while candidate.path != "/" {
            if candidate.pathExtension.lowercased() == "xctest" {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(
                    atPath: candidate.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    return nil
                }
                let canonical = candidate.resolvingSymlinksInPath()
                guard let bundle = Bundle(url: canonical),
                    let executable = bundle.executableURL,
                    FileManager.default.isExecutableFile(atPath: executable.path)
                else {
                    return nil
                }
                return canonical
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent != candidate else { break }
            candidate = parent
        }
        return nil
    }

    private static func testBundleExecutableURL(for bundleURL: URL) -> URL? {
        guard let bundle = Bundle(url: bundleURL),
            let executable = bundle.executableURL,
            FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            return nil
        }
        return executable.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isXCTestToolPath(_ executableURL: URL?) -> Bool {
        guard let path = executableURL?.path else { return false }
        let normalized = path.lowercased()
        return normalized.contains("/contents/developer/")
            || normalized == "/usr/bin/xctest"
    }

    private static func isXCTestRuntimeLoaded() -> Bool {
        NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
    }

    private static func safeTemporaryRoots() -> [URL] {
        [
            URL(fileURLWithPath: "/tmp", isDirectory: true),
            FileManager.default.temporaryDirectory,
        ].map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    private static func isPathStrictlyInside(_ path: URL, boundary: URL) -> Bool {
        path.path.hasPrefix(boundary.path + "/")
    }

    /// Test fixtures historically create their already-isolated temporary
    /// directory using the process umask. Tighten an owned directory to 0700
    /// before accepting it, then verify the resulting mode. The shared
    /// temporary boundary itself is never accepted, so this cannot chmod
    /// `/tmp` or the per-user temporary parent.
    private static func ensurePrivatePermissions(
        atPath path: String,
        fileManager: FileManager
    ) -> Bool {
        guard var attributes = try? fileManager.attributesOfItem(atPath: path),
            let owner = attributes[.ownerAccountID] as? NSNumber,
            owner.uint32Value == geteuid(),
            let permissions = attributes[.posixPermissions] as? NSNumber
        else {
            return false
        }
        if permissions.intValue & 0o077 != 0 {
            do {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
                attributes = try fileManager.attributesOfItem(atPath: path)
            } catch {
                return false
            }
        }
        guard let verified = attributes[.posixPermissions] as? NSNumber else { return false }
        return verified.intValue & 0o077 == 0
    }

    private static func hasValue(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
