//
//  InstallationDiagnostics.swift
//  OsaurusCLI
//
//  Read-only diagnostics for the CLI/app installation boundary. The CLI and
//  app communicate through a distributed notification, so version skew or a
//  duplicate LaunchServices registration can otherwise look like a generic
//  server timeout.
//

import Foundation
import Darwin

public enum StartupDiagnosticKind: String, Codable, Sendable {
    case healthy
    case appAbsent = "app_absent"
    case appStale = "app_stale_incompatible"
    case appNewer = "app_newer_than_cli"
    case duplicateBundles = "duplicate_bundles"
    case portBusy = "port_busy"
    case serverUnhealthy = "server_unhealthy"
    case serverNotRunning = "server_not_running"
    case startupTimeout = "startup_timeout"
}

public enum SignatureDiagnosticState: String, Codable, Sendable {
    case valid
    case invalid
    case timedOut = "timed_out"
    case unchecked
}

public struct AppBundleDiagnostic: Codable, Equatable, Sendable {
    public let path: String
    public let version: String?
    public let build: String?
    public let isRunning: Bool
    public let isCompanion: Bool
    public let signature: SignatureDiagnosticState
    public let notarization: SignatureDiagnosticState

    public init(
        path: String,
        version: String?,
        build: String?,
        isRunning: Bool,
        isCompanion: Bool,
        signature: SignatureDiagnosticState = .unchecked,
        notarization: SignatureDiagnosticState = .unchecked
    ) {
        self.path = path
        self.version = version
        self.build = build
        self.isRunning = isRunning
        self.isCompanion = isCompanion
        self.signature = signature
        self.notarization = notarization
    }
}

public struct InstallationDiagnosticReport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let cliPath: String
    public let cliVersion: String?
    public let cliBuild: String?
    public let requestedPort: Int
    public let configuredPort: Int?
    public let serverHealthy: Bool
    public let portOwner: String?
    public let modelRoot: String
    public let modelRootSource: String
    public let modelRootReadable: Bool
    public let modelCount: Int
    public let modelCountComplete: Bool
    public let apps: [AppBundleDiagnostic]
    public let diagnosis: StartupDiagnosticKind
    public let recommendation: String

    public func redacted(homeDirectory: String = NSHomeDirectory()) -> Self {
        func scrub(_ value: String) -> String {
            var output = value
            let patterns = [#"/System/Volumes/Data/Users/[^/\s]+"#, #"/Users/[^/\s]+"#]
            for pattern in patterns {
                output = output.replacingOccurrences(
                    of: pattern,
                    with: "~",
                    options: .regularExpression
                )
            }
            let homes = [
                homeDirectory,
                URL(fileURLWithPath: homeDirectory).resolvingSymlinksInPath().path,
                FileManager.default.homeDirectoryForCurrentUser.path,
                FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path,
            ]
            for home in Set(homes) where !home.isEmpty && home != "/" {
                output = output.replacingOccurrences(of: home, with: "~")
            }
            return output
        }
        return Self(
            generatedAt: generatedAt,
            cliPath: scrub(cliPath),
            cliVersion: cliVersion,
            cliBuild: cliBuild,
            requestedPort: requestedPort,
            configuredPort: configuredPort,
            serverHealthy: serverHealthy,
            portOwner: portOwner,
            modelRoot: scrub(modelRoot),
            modelRootSource: modelRootSource,
            modelRootReadable: modelRootReadable,
            modelCount: modelCount,
            modelCountComplete: modelCountComplete,
            apps: apps.map {
                AppBundleDiagnostic(
                    path: scrub($0.path),
                    version: $0.version,
                    build: $0.build,
                    isRunning: $0.isRunning,
                    isCompanion: $0.isCompanion,
                    signature: $0.signature,
                    notarization: $0.notarization
                )
            },
            diagnosis: diagnosis,
            recommendation: scrub(recommendation)
        )
    }
}

public struct ResolvedCLIVersion: Equatable, Sendable {
    public let version: String?
    public let build: String?
    public let companionAppPath: String?
}

public enum CLIVersionResolver {
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executablePath: String = CommandLine.arguments.first ?? ""
    ) -> ResolvedCLIVersion {
        if let version = nonempty(environment["OSAURUS_VERSION"]) {
            return ResolvedCLIVersion(
                version: version,
                build: nonempty(environment["OSAURUS_BUILD_NUMBER"]),
                companionAppPath: companionAppPath(for: executablePath)
            )
        }

        let companion = companionAppPath(for: executablePath)
        if let companion,
            let metadata = bundleMetadata(at: companion),
            let version = metadata.version {
            return ResolvedCLIVersion(
                version: version,
                build: metadata.build,
                companionAppPath: companion
            )
        }
        return ResolvedCLIVersion(version: nil, build: nil, companionAppPath: companion)
    }

    public static func companionAppPath(for executablePath: String) -> String? {
        guard !executablePath.isEmpty else { return nil }
        let resolved = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path
        guard let range = resolved.range(of: ".app/Contents/") else { return nil }
        return String(resolved[..<range.lowerBound]) + ".app"
    }

    public static func bundleMetadata(at appPath: String) -> (version: String?, build: String?)? {
        let plist = URL(fileURLWithPath: appPath)
            .appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
            let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = object as? [String: Any]
        else { return nil }
        return (
            nonempty(dictionary["CFBundleShortVersionString"] as? String),
            nonempty(dictionary["CFBundleVersion"] as? String)
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}

public enum InstallationDiagnostics {
    @MainActor
    public static func collect(
        requestedPort: Int? = nil,
        includeSignatureChecks: Bool = false,
        startupAttempted: Bool = false,
        includeModelInventory: Bool = true,
        includeComprehensiveAppSearch: Bool = true
    ) async -> InstallationDiagnosticReport {
        let configuredPort = Configuration.resolveConfiguredPort()
        let port = requestedPort ?? configuredPort ?? 1337
        let runningPath = AppControl.runningAppBundlePath()
        let cliPath = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath().path
        let cli = CLIVersionResolver.resolve(
            executablePath: cliPath
        )
        // NSWorkspace is main-thread-bound. Keep discovery on this MainActor
        // entry point, then move filesystem-only work off actor below.
        let discoveredPaths = AppControl.findAppBundlePaths(
            includeSpotlightSearch: includeComprehensiveAppSearch
        )
        let appPaths = await Task.detached(priority: .utility) {
            AppControl.deduplicatedBundlePaths(
                discoveredPaths + [runningPath, cli.companionAppPath].compactMap { $0 }
            ).filter { FileManager.default.fileExists(atPath: $0) }
        }.value
        let healthy = await ServerControl.checkHealth(port: port)
        let owner = await Task.detached(priority: .utility) { portOwner(port: port) }.value

        let apps = await Task.detached(priority: .utility) {
            appPaths.map { path -> AppBundleDiagnostic in
                let metadata = CLIVersionResolver.bundleMetadata(at: path)
                let signature = includeSignatureChecks
                    ? assess(executable: "/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", path])
                    : .unchecked
                let notarization = includeSignatureChecks
                    ? assess(executable: "/usr/sbin/spctl", arguments: ["-a", "-t", "execute", path])
                    : .unchecked
                return AppBundleDiagnostic(
                    path: path,
                    version: metadata?.version,
                    build: metadata?.build,
                    isRunning: normalized(path) == runningPath.map(normalized),
                    isCompanion: normalized(path) == cli.companionAppPath.map(normalized),
                    signature: signature,
                    notarization: notarization
                )
            }
        }.value

        let diagnosis = classify(
            apps: apps,
            cliVersion: cli.version,
            cliBuild: cli.build,
            healthy: healthy,
            portOwner: owner,
            startupAttempted: startupAttempted
        )
        let modelResolution = Configuration.resolveModelsDirectoryWithSource()
        let modelSnapshot = await Task.detached(priority: .utility) {
            let readable = FileManager.default.isReadableFile(atPath: modelResolution.url.path)
            guard includeModelInventory else {
                return (readable, (count: 0, complete: false))
            }
            let count = countModelBundles(in: modelResolution.url)
            return (readable, count)
        }.value

        return InstallationDiagnosticReport(
            generatedAt: Date(),
            cliPath: cliPath,
            cliVersion: cli.version,
            cliBuild: cli.build,
            requestedPort: port,
            configuredPort: configuredPort,
            serverHealthy: healthy,
            portOwner: owner,
            modelRoot: modelResolution.url.path,
            modelRootSource: modelResolution.source,
            modelRootReadable: modelSnapshot.0,
            modelCount: modelSnapshot.1.count,
            modelCountComplete: modelSnapshot.1.complete,
            apps: apps,
            diagnosis: diagnosis,
            recommendation: recommendation(for: diagnosis, port: port)
        )
    }

    nonisolated public static func classify(
        apps: [AppBundleDiagnostic],
        cliVersion: String?,
        cliBuild: String? = nil,
        healthy: Bool,
        portOwner: String?,
        startupAttempted: Bool = false
    ) -> StartupDiagnosticKind {
        if apps.count > 1 { return .duplicateBundles }
        if let app = apps.first,
            let appVersion = app.version,
            let cliVersion,
            compareVersions(appVersion, cliVersion) != .orderedSame {
            return compareVersions(appVersion, cliVersion) == .orderedAscending
                ? .appStale
                : .appNewer
        }
        if let appBuild = apps.first?.build, let cliBuild,
            compareVersions(appBuild, cliBuild) != .orderedSame {
            return compareVersions(appBuild, cliBuild) == .orderedAscending ? .appStale : .appNewer
        }
        if let portOwner {
            if !isOsaurusPortOwner(portOwner) { return .portBusy }
            if !healthy { return .serverUnhealthy }
        }
        if healthy { return .healthy }
        if apps.isEmpty { return .appAbsent }
        return startupAttempted ? .startupTimeout : .serverNotRunning
    }

    nonisolated public static func recommendation(
        for diagnosis: StartupDiagnosticKind,
        port: Int
    ) -> String {
        switch diagnosis {
        case .healthy:
            return "No installation problem detected."
        case .appAbsent:
            return "Install Osaurus.app, then run `osaurus serve --port \(port)` again."
        case .appStale:
            return "Update the installed Osaurus app so it matches the CLI, then retry."
        case .appNewer:
            return "Update the CLI or invoke the helper bundled with the installed Osaurus app."
        case .duplicateBundles:
            return "Quit Osaurus and remove or archive duplicate registered app bundles, then launch the intended app explicitly."
        case .portBusy:
            return "Choose another port or stop the non-Osaurus process using port \(port)."
        case .serverUnhealthy:
            return "The Osaurus process owns port \(port) but is unhealthy. Quit it, relaunch the intended app, and inspect `osaurus doctor`."
        case .serverNotRunning:
            return "The installation looks usable, but the server is not running. Launch Osaurus or run `osaurus serve --port \(port)`."
        case .startupTimeout:
            return "Launch the intended Osaurus app explicitly, then retry `osaurus serve --port \(port)`."
        }
    }

    nonisolated private static func portOwner(port: Int) -> String? {
        let result = run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"],
            timeout: 1.0,
            captureOutput: true
        )
        guard result.state == .valid, !result.output.isEmpty else { return nil }
        let fields = result.output.split(separator: "\n").map(String.init)
        let pid = fields.first { $0.hasPrefix("p") }.map { String($0.dropFirst()) }
        let command = fields.first { $0.hasPrefix("c") }.map { String($0.dropFirst()) }
        return [command, pid.map { "pid \($0)" }].compactMap { $0 }.joined(separator: " ")
    }

    nonisolated private static func assess(executable: String, arguments: [String]) -> SignatureDiagnosticState {
        run(executable: executable, arguments: arguments, timeout: 2.0).state
    }

    nonisolated private static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        captureOutput: Bool = false
    ) -> (state: SignatureDiagnosticState, output: String) {
        let process = Process()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = captureOutput ? pipe : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return (.unchecked, "")
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 0.5) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            process.waitUntilExit()
            return (.timedOut, "")
        }
        let output: String
        if captureOutput,
            let data = try? pipe.fileHandleForReading.readToEnd(),
            let decoded = String(data: data, encoding: .utf8) {
            output = decoded
        } else {
            output = ""
        }
        return (process.terminationStatus == 0 ? .valid : .invalid, output)
    }

    nonisolated private static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    nonisolated private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = normalizedVersionComponents(lhs)
        let right = normalizedVersionComponents(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    nonisolated private static func normalizedVersionComponents(_ value: String) -> [Int] {
        value.split(separator: ".").map { component in
            Int(component.prefix { $0.isNumber }) ?? 0
        }
    }

    nonisolated private static func isOsaurusPortOwner(_ owner: String) -> Bool {
        let command = owner.split(separator: " ").first.map(String.init)?.lowercased()
        return command == "osaurus"
    }

    nonisolated static func countModelBundles(
        in root: URL,
        maximumEntries: Int = 100_000
    ) -> (count: Int, complete: Bool) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return (0, false) }
        var modelDirectories = Set<String>()
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > maximumEntries { return (modelDirectories.count, false) }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let name = url.lastPathComponent.lowercased()
            if name == "config.json" || name == "tokenizer_config.json" || name.hasSuffix(".safetensors") {
                modelDirectories.insert(url.deletingLastPathComponent().standardizedFileURL.path)
            }
        }
        return (modelDirectories.count, true)
    }
}
