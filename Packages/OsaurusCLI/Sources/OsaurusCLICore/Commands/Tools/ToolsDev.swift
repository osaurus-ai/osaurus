//
//  ToolsDev.swift
//  osaurus
//
//  Development mode for plugins. Supports two modes:
//
//  1. Project-root mode (no args): reads osaurus-plugin.json from cwd,
//     builds, installs, and watches for source changes automatically.
//
//  2. Legacy watch mode (plugin_id arg): watches an already-installed
//     plugin's dylib for changes and sends reload signals.
//

import Foundation
import OsaurusRepository

private nonisolated(unsafe) var devProxyConfigFile: URL?
private nonisolated(unsafe) var signalSource: DispatchSourceSignal?

public struct ToolsDev {

    // MARK: - Plugin Config

    private struct PluginConfig: Decodable {
        let plugin_id: String
        let version: String
    }

    private enum Language {
        case swift
        case rust
    }

    // MARK: - Entry Point

    public static func execute(args: [String]) async {
        var webProxyURL: String?
        var flagConsumedIndices = Set<Int>()

        if let idx = args.firstIndex(of: "--web-proxy"), idx + 1 < args.count {
            webProxyURL = args[idx + 1]
            flagConsumedIndices.insert(idx)
            flagConsumedIndices.insert(idx + 1)
        }

        let positionalArgs = args.enumerated()
            .filter { !flagConsumedIndices.contains($0.offset) && !$0.element.hasPrefix("--") }
            .map { $0.element }

        if let pluginId = positionalArgs.first {
            await runLegacyWatchMode(pluginId: pluginId, webProxyURL: webProxyURL)
        } else {
            await runProjectMode(webProxyURL: webProxyURL)
        }
    }

    // MARK: - Project-Root Mode

    private static func runProjectMode(webProxyURL: String?) async {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)

        let configURL = cwd.appendingPathComponent("osaurus-plugin.json")
        guard fm.fileExists(atPath: configURL.path) else {
            fputs("В текущем каталоге не найден osaurus-plugin.json.\n", stderr)
            fputs("Запустите команду из корня проекта плагина или передайте plugin_id:\n", stderr)
            fputs("  osaurus tools dev <plugin_id>\n\n", stderr)
            fputs("Чтобы создать новый проект плагина:\n", stderr)
            fputs("  osaurus tools create MyPlugin\n", stderr)
            exit(EXIT_FAILURE)
        }

        guard let configData = try? Data(contentsOf: configURL),
            let config = try? JSONDecoder().decode(PluginConfig.self, from: configData)
        else {
            fputs("Не удалось разобрать osaurus-plugin.json\n", stderr)
            exit(EXIT_FAILURE)
        }

        let language: Language
        if fm.fileExists(atPath: cwd.appendingPathComponent("Package.swift").path) {
            language = .swift
        } else if fm.fileExists(atPath: cwd.appendingPathComponent("Cargo.toml").path) {
            language = .rust
        } else {
            fputs("Не удалось определить язык проекта. Ожидался Package.swift или Cargo.toml в текущем каталоге.\n", stderr)
            exit(EXIT_FAILURE)
        }

        print("  Плагин: \(config.plugin_id) v\(config.version)")

        // Initial build
        print("  Сборка...", terminator: "")
        fflush(stdout)
        let buildStart = Date()
        guard build(language: language, cwd: cwd) else {
            fputs(" неудачно\nСборка не удалась. Исправьте ошибки выше и попробуйте снова.\n", stderr)
            exit(EXIT_FAILURE)
        }
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(buildStart))
        print(" готово (\(elapsed)с)")

        guard let dylibURL = findBuiltDylib(language: language, cwd: cwd) else {
            fputs("В выходных данных сборки не найден .dylib.\n", stderr)
            exit(EXIT_FAILURE)
        }

        let installDir = installPlugin(
            config: config,
            dylibURL: dylibURL,
            projectDir: cwd
        )

        print("  Установлено в \(installDir.path)")

        setupWebProxy(pluginId: config.plugin_id, webProxyURL: webProxyURL)
        await AppControl.launchAppIfNeeded()
        sendReload()

        if let proxy = webProxyURL {
            print("  Веб-прокси: \(proxy)")
        }
        print("  Наблюдение за изменениями... Нажмите Ctrl+C, чтобы остановить.\n")

        setupSignalHandler()

        let srcDir = sourceDir(language: language, cwd: cwd)
        var lastSourceMtime = latestMtime(in: srcDir)
        var lastAssetMtime = latestAssetMtime(cwd: cwd)

        while true {
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            let currentSourceMtime = latestMtime(in: srcDir)
            let currentAssetMtime = latestAssetMtime(cwd: cwd)

            if currentSourceMtime > lastSourceMtime {
                print("[\(timestamp())] Источник изменён, пересборка...")
                if build(language: language, cwd: cwd) {
                    if let newDylib = findBuiltDylib(language: language, cwd: cwd) {
                        _ = installPlugin(config: config, dylibURL: newDylib, projectDir: cwd)
                        sendReload()
                        print("[\(timestamp())] Сигнал перезагрузки отправлен.")
                    }
                } else {
                    fputs("[\(timestamp())] Сборка не удалась. Ждём следующего изменения...\n", stderr)
                }
                lastSourceMtime = latestMtime(in: srcDir)
                lastAssetMtime = latestAssetMtime(cwd: cwd)
            } else if currentAssetMtime > lastAssetMtime {
                print("[\(timestamp())] Активы изменены, копирование...")
                _ = installPlugin(config: config, dylibURL: dylibURL, projectDir: cwd)
                sendReload()
                print("[\(timestamp())] Сигнал перезагрузки отправлен.")
                lastAssetMtime = currentAssetMtime
            }
        }
    }

    // MARK: - Legacy Watch Mode

    private static func runLegacyWatchMode(pluginId: String, webProxyURL: String?) async {
        let pluginDir = ToolsPaths.toolsRootDirectory()
            .appendingPathComponent(pluginId, isDirectory: true)

        guard FileManager.default.fileExists(atPath: pluginDir.path) else {
            fputs("Плагин не найден: \(pluginId)\n", stderr)
            fputs("Сначала установите его или создайте каталог по адресу: \(pluginDir.path)\n", stderr)
            exit(EXIT_FAILURE)
        }

        print("Запуск режима разработки для \(pluginId)")
        if let proxy = webProxyURL {
            print("Веб-прокси: \(proxy)")
            print("Запросы к /plugins/\(pluginId)/app/* будут проксированы через \(proxy)")
        }
        print("Наблюдение за изменениями .dylib в \(pluginDir.path)")
        print("Нажмите Ctrl+C, чтобы остановить.\n")

        setupWebProxy(pluginId: pluginId, webProxyURL: webProxyURL)
        setupSignalHandler()

        var lastModified: Date?

        func findDylib() -> URL? {
            let currentLink = pluginDir.appendingPathComponent("current")
            let versionDir: URL?
            if let dest = try? FileManager.default.destinationOfSymbolicLink(
                atPath: currentLink.path
            ) {
                versionDir = pluginDir.appendingPathComponent(dest, isDirectory: true)
            } else {
                versionDir = try? FileManager.default.contentsOfDirectory(
                    at: pluginDir,
                    includingPropertiesForKeys: nil,
                    options: .skipsHiddenFiles
                ).filter(\.hasDirectoryPath).first
            }
            guard let dir = versionDir else { return nil }

            if let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) {
                for case let url as URL in enumerator where url.pathExtension == "dylib" {
                    return url
                }
            }
            return nil
        }

        func dylibMtime(_ url: URL) -> Date? {
            try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }

        if let dylib = findDylib() {
            lastModified = dylibMtime(dylib)
        }

        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)

            guard let dylib = findDylib() else { continue }
            let modified = dylibMtime(dylib)

            if let modified, let last = lastModified, modified > last {
                print("[\(timestamp())] Обнаружено изменение dylib, отправка сигнала перезагрузки...")
                sendReload()
                lastModified = modified
                print("[\(timestamp())] Сигнал перезагрузки отправлен.")
            } else if lastModified == nil {
                lastModified = modified
            }
        }
    }

    // MARK: - Build

    @discardableResult
    private static func build(language: Language, cwd: URL) -> Bool {
        let process = Process()
        process.currentDirectoryURL = cwd
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")

        switch language {
        case .swift:
            process.arguments = ["swift", "build", "-c", "release"]
        case .rust:
            process.arguments = ["cargo", "build", "--release"]
        }

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func findBuiltDylib(language: Language, cwd: URL) -> URL? {
        let releaseDir = language == .swift ? ".build/release" : "target/release"
        let buildDir = cwd.appendingPathComponent(releaseDir, isDirectory: true)
            .resolvingSymlinksInPath()

        return
            (try? FileManager.default.contentsOfDirectory(
                at: buildDir,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles
            ))?.first { $0.pathExtension == "dylib" }
    }

    // MARK: - Install

    @discardableResult
    private static func installPlugin(
        config: PluginConfig,
        dylibURL: URL,
        projectDir: URL
    ) -> URL {
        let fm = FileManager.default
        let versionDir =
            ToolsPaths.toolsRootDirectory()
            .appendingPathComponent(config.plugin_id, isDirectory: true)
            .appendingPathComponent(config.version, isDirectory: true)

        try? fm.createDirectory(at: versionDir, withIntermediateDirectories: true)

        // Use a unique filename per rebuild so dlopen treats each as a fresh
        // library with valid PAC signatures (ARM64 reuses stale PAC otherwise).
        if let existing = try? fm.contentsOfDirectory(at: versionDir, includingPropertiesForKeys: nil) {
            for file in existing where file.pathExtension == "dylib" {
                try? fm.removeItem(at: file)
            }
        }
        let stem = dylibURL.deletingPathExtension().lastPathComponent
        let uniqueName = "\(stem)_\(Int(Date().timeIntervalSince1970 * 1000)).dylib"
        let destDylib = versionDir.appendingPathComponent(uniqueName)
        try? fm.copyItem(at: dylibURL, to: destDylib)

        // Remove stale receipt.json so it doesn't block DEBUG loading
        let staleReceipt = versionDir.appendingPathComponent("receipt.json")
        if fm.fileExists(atPath: staleReceipt.path) {
            try? fm.removeItem(at: staleReceipt)
        }

        // Copy companion files
        let companions = ["README.md", "CHANGELOG.md"]
        for name in companions {
            let src = projectDir.appendingPathComponent(name)
            let dst = versionDir.appendingPathComponent(name)
            if fm.fileExists(atPath: src.path) {
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
        }

        // Copy SKILL.md into skills/ subdirectory (where PluginManager expects it)
        let skillSrc = projectDir.appendingPathComponent("SKILL.md")
        if fm.fileExists(atPath: skillSrc.path) {
            let skillsDir = versionDir.appendingPathComponent("skills", isDirectory: true)
            try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)
            let skillDst = skillsDir.appendingPathComponent("SKILL.md")
            try? fm.removeItem(at: skillDst)
            try? fm.copyItem(at: skillSrc, to: skillDst)
        }

        // Copy web/ directory
        let webSrc = projectDir.appendingPathComponent("web", isDirectory: true)
        let webDst = versionDir.appendingPathComponent("web", isDirectory: true)
        if fm.fileExists(atPath: webSrc.path) {
            try? fm.removeItem(at: webDst)
            try? fm.copyItem(at: webSrc, to: webDst)
        }

        // Update current symlink
        let pluginDir = versionDir.deletingLastPathComponent()
        let currentLink = pluginDir.appendingPathComponent("current")
        try? fm.removeItem(at: currentLink)
        try? fm.createSymbolicLink(
            atPath: currentLink.path,
            withDestinationPath: config.version
        )

        return versionDir
    }

    // MARK: - File Watching Helpers

    private static func sourceDir(language: Language, cwd: URL) -> URL {
        switch language {
        case .swift:
            return cwd.appendingPathComponent("Sources", isDirectory: true)
        case .rust:
            return cwd.appendingPathComponent("src", isDirectory: true)
        }
    }

    private static func latestMtime(in directory: URL) -> Date {
        var latest = Date.distantPast
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else { return latest }

        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                let mtime = values.contentModificationDate, mtime > latest
            {
                latest = mtime
            }
        }
        return latest
    }

    private static func latestAssetMtime(cwd: URL) -> Date {
        var latest = Date.distantPast

        let companions = ["SKILL.md", "README.md", "CHANGELOG.md"]
        for name in companions {
            let url = cwd.appendingPathComponent(name)
            if let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                let mtime = values.contentModificationDate, mtime > latest
            {
                latest = mtime
            }
        }

        let webMtime = latestMtime(in: cwd.appendingPathComponent("web", isDirectory: true))
        if webMtime > latest { latest = webMtime }

        return latest
    }

    // MARK: - Shared Helpers

    private static func sendReload() {
        AppControl.postDistributedNotification(
            name: "com.dinoki.osaurus.control.toolsReload",
            userInfo: [:]
        )
    }

    private static func setupWebProxy(pluginId: String, webProxyURL: String?) {
        guard let proxy = webProxyURL else { return }
        let configDir = ToolsPaths.root().appendingPathComponent("config", isDirectory: true)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let devConfig: [String: Any] = [
            "plugin_id": pluginId,
            "web_proxy": proxy,
        ]
        let data = try? JSONSerialization.data(withJSONObject: devConfig, options: .prettyPrinted)
        let configFile = configDir.appendingPathComponent("dev-proxy.json")
        try? data?.write(to: configFile)
        devProxyConfigFile = configFile
    }

    private static func setupSignalHandler() {
        signal(SIGINT, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        src.setEventHandler { cleanupAndExit() }
        src.resume()
        signalSource = src
    }

    private static func cleanupAndExit() {
        if let file = devProxyConfigFile {
            try? FileManager.default.removeItem(at: file)
        }
        _Exit(0)
    }

    private static let timestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        return fmt
    }()

    private static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }
}
