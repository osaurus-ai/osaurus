//
//  ToolsPackage.swift
//  osaurus
//
//  Command to package a plugin by creating a zip file containing the dylib
//  and v2 companion files (web/, SKILL.md, README.md, CHANGELOG.md).
//  Output format: <plugin_id>-<version>.zip
//

import Foundation

public struct ToolsPackage {
    static let companionFiles = ["SKILL.md", "README.md", "CHANGELOG.md"]
    static let companionDirs = ["web"]

    static func findDylibs(in directory: URL) throws -> [String] {
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return contents.filter { $0.hasSuffix(".dylib") }
    }

    static func collectCompanionEntries(in directory: URL) -> [String] {
        let fm = FileManager.default
        var entries: [String] = []

        for file in companionFiles {
            if fm.fileExists(atPath: directory.appendingPathComponent(file).path) {
                entries.append(file)
            }
        }

        for dirName in companionDirs {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: directory.appendingPathComponent(dirName).path, isDirectory: &isDir),
                isDir.boolValue
            {
                entries.append(dirName)
            }
        }

        return entries
    }

    static func zipName(pluginId: String, version: String) -> String {
        "\(pluginId)-\(version).zip"
    }

    public static func execute(args: [String]) {
        guard args.count >= 2 else {
            fputs("Использование: osaurus tools package <plugin_id> <version> [dylib_path]\n", stderr)
            fputs("  Если dylib_path не указан, .dylib-файлы будут найдены автоматически в текущем каталоге.\n", stderr)
            fputs("  Также включает web/, SKILL.md, README.md и CHANGELOG.md, если они есть.\n", stderr)
            exit(EXIT_FAILURE)
        }

        let pluginId = args[0]
        let version = args[1]

        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)

        var dylibPaths: [String] = []

        if args.count >= 3 {
            let dylibPath = args[2]
            guard fm.fileExists(atPath: cwd.appendingPathComponent(dylibPath).path) else {
                fputs("Dylib не найден: \(dylibPath)\n", stderr)
                exit(EXIT_FAILURE)
            }
            dylibPaths.append(dylibPath)
        } else {
            do {
                dylibPaths = try findDylibs(in: cwd)
            } catch {
                fputs("Не удалось прочитать текущий каталог: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            guard !dylibPaths.isEmpty else {
                fputs("В текущем каталоге не найдено .dylib-файлов.\n", stderr)
                fputs("Сначала соберите плагин или явно укажите путь к dylib.\n", stderr)
                exit(EXIT_FAILURE)
            }
        }

        var zipEntries = dylibPaths
        zipEntries.append(contentsOf: collectCompanionEntries(in: cwd))

        let name = zipName(pluginId: pluginId, version: version)
        let zipURL = cwd.appendingPathComponent(name)

        if fm.fileExists(atPath: zipURL.path) {
            try? fm.removeItem(at: zipURL)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = cwd
        proc.arguments = ["-q", "-r", zipURL.path] + zipEntries

        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 {
                fputs("Команда zip завершилась с ошибкой; убедитесь, что /usr/bin/zip доступен.\n", stderr)
                exit(EXIT_FAILURE)
            }
        } catch {
            fputs("Не удалось запустить zip: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }

        let extras = zipEntries.filter { !$0.hasSuffix(".dylib") }
        if !extras.isEmpty {
            print("Создан \(name) (включая: \(extras.joined(separator: ", ")))")
        } else {
            print("Создан \(name)")
        }
        print("Установите командой: osaurus tools install ./\(name)")
        exit(EXIT_SUCCESS)
    }
}
