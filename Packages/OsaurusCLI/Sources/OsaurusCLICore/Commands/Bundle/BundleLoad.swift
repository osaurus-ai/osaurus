//
//  BundleLoad.swift
//  osaurus
//
//  Load and start an MCP Bundle (.mcpb file).
//

import Foundation
import MCP

enum BundleLoadError: Error, CustomStringConvertible {
    case missingPath
    case fileNotFound(String)
    case invalidExtension
    case extractionFailed(String)
    case missingManifest
    case invalidManifest(String)
    case serverLaunchFailed(String)
    case toolDiscoveryFailed(String)

    var description: String {
        switch self {
        case .missingPath:
            return "Ошибка: требуется путь к bundle\n  Использование: osaurus bundle load <path.mcpb>"
        case let .fileNotFound(path):
            return "Ошибка: файл не найден: \(path)"
        case .invalidExtension:
            return "Ошибка: файл должен иметь расширение .mcpb"
        case let .extractionFailed(reason):
            return "Ошибка: не удалось извлечь bundle: \(reason)"
        case .missingManifest:
            return "Ошибка: manifest.json не найден в bundle"
        case let .invalidManifest(reason):
            return "Ошибка: неверный формат манифеста: \(reason)"
        case let .serverLaunchFailed(reason):
            return "Ошибка: не удалось запустить MCP-сервер: \(reason)"
        case let .toolDiscoveryFailed(reason):
            return "Ошибка: не удалось обнаружить инструменты: \(reason)"
        }
    }
}

struct BundleLoad {
    static func execute(args: [String]) async {
        do {
            try await run(args: args)
        } catch {
            fputs("\(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func run(args: [String]) async throws {
        // Parse arguments
        var bundlePath: String?
        var displayName: String?
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--name" {
                if i + 1 < args.count {
                    displayName = args[i + 1]
                    i += 2
                } else {
                    throw BundleLoadError.missingPath
                }
            } else if !arg.hasPrefix("--") {
                bundlePath = arg
                i += 1
            } else {
                i += 1
            }
        }

        guard let path = bundlePath else {
            throw BundleLoadError.missingPath
        }

        // Validate file
        guard FileManager.default.fileExists(atPath: path) else {
            throw BundleLoadError.fileNotFound(path)
        }

        guard path.lowercased().hasSuffix(".mcpb") else {
            throw BundleLoadError.invalidExtension
        }

        // Extract bundle
        let bundleInfo = try MCPBundleManager.extract(path)
        defer { bundleInfo.cleanup() }

        // Parse manifest
        let manifest = try bundleInfo.parseManifest()

        // Display bundle info
        print("Пакет: \(displayName ?? manifest.displayName ?? manifest.name)")
        print("Версия: \(manifest.version)")
        if let description = manifest.description {
            print("Описание: \(description)")
        }
        print("")

        // Launch server
        let serverInfo = try await bundleInfo.launchServer(workingDirectory: bundleInfo.extractedPath)
        defer {
            serverInfo.shutdown()
        }

        // Discover tools via MCP SDK
        do {
            let tools = try await serverInfo.discoverTools()

            if tools.isEmpty {
                print("Инструменты не найдены.")
            } else {
                print("Найдено \(tools.count) инструмент(ов):")
                for tool in tools {
                    print("  - \(tool.name): \(tool.description ?? "")")
                }
            }
        } catch {
            print("Предупреждение: не удалось обнаружить инструменты: \(error)")
        }

        print("")
        print("Сервер запущен. Нажмите Ctrl+C, чтобы остановить.")
        print("")

        // Keep alive until interrupt
        signal(SIGINT) { _ in
            exit(EXIT_SUCCESS)
        }

        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
