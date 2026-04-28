//
//  OsaurusCLI.swift
//  osaurus
//
//  Main entry point for the Osaurus CLI. Parses command-line arguments and routes to appropriate command handlers.
//

import Foundation
import OsaurusCLICore

@main
struct OsaurusCLI {
    private enum CommandType {
        case status
        case serve([String])
        case stop
        case list
        case show(String)
        case run(String)
        case pull(String)
        case mcp
        case ui
        case tools([String])
        case manifest([String])
        case bundle([String])
        case version
        case help
    }

    private static func parseCommand(_ args: ArraySlice<String>) -> CommandType? {
        guard let command = args.first else { return nil }
        let rest = Array(args.dropFirst())
        switch command {
        case "status": return .status
        case "serve": return .serve(rest)
        case "stop": return .stop
        case "list": return .list
        case "show":
            if let modelId = rest.first, !modelId.isEmpty { return .show(modelId) }
            return nil
        case "run":
            if let modelId = rest.first, !modelId.isEmpty { return .run(modelId) }
            return nil
        case "pull":
            if let modelId = rest.first, !modelId.isEmpty { return .pull(modelId) }
            return nil
        case "mcp": return .mcp
        case "ui": return .ui
        case "tools": return .tools(rest)
        case "manifest": return .manifest(rest)
        case "bundle": return .bundle(rest)
        case "version", "--version", "-v": return .version
        case "help", "-h", "--help": return .help
        default: return nil
        }
    }

    static func main() async {
        let arguments = CommandLine.arguments.dropFirst()
        guard let cmd = parseCommand(arguments) else {
            if let first = arguments.first { fputs("Неизвестная или недопустимая команда: \(first)\n\n", stderr) }
            printUsage()
            exit(EXIT_FAILURE)
        }

        switch cmd {
        case .status:
            await StatusCommand.execute(args: [])
        case .serve(let args):
            await ServeCommand.execute(args: args)
        case .stop:
            await StopCommand.execute(args: [])
        case .list:
            await ListCommand.execute(args: [])
        case .show(let modelId):
            await ShowCommand.execute(args: [modelId])
        case .run(let modelId):
            await RunCommand.execute(args: [modelId])
        case .pull(let modelId):
            await PullCommand.execute(args: [modelId])
        case .mcp:
            await MCPCommand.execute(args: [])
        case .ui:
            await UICommand.execute(args: [])
        case .tools(let args):
            await ToolsCommand.execute(args: args)
        case .manifest(let args):
            await ManifestCommand.execute(args: args)
        case .bundle(let args):
            await BundleCommand.execute(args: args)
        case .version:
            await VersionCommand.execute(args: [])
        case .help:
            printUsage()
            exit(EXIT_SUCCESS)
        }
    }

    private static func printUsage() {
        let usage = """
            osaurus - CLI для Osaurus

            Использование:
              osaurus serve [--port N] [--expose] [--yes|-y]
                                      Запускает сервер (по умолчанию только localhost). Если указан --expose,
                                      появится предупреждение, если не передан --yes.
              osaurus stop            Останавливает сервер
              osaurus mcp             Запускает MCP stdio сервер с проксированием к локальному HTTP
              osaurus version         Показывает версию (также: --version или -v)
              osaurus status          Проверяет, запущен ли сервер Osaurus
              osaurus list            Показывает доступные идентификаторы моделей
              osaurus show <model_id> Показывает метаданные модели
              osaurus pull <model_id> Скачивает модель с Hugging Face
              osaurus run <model_id>  Общается со скачанной моделью (интерактивно)
              osaurus ui              Показывает всплывающее меню Osaurus в строке меню
              osaurus tools list      Показывает установленные инструменты
              osaurus tools install <plugin_id|url-or-path>
                                      Устанавливает инструмент из реестра или из локального пути/URL
              osaurus tools search <query>
                                      Ищет инструменты в реестре
              osaurus tools outdated  Проверяет устаревшие инструменты
              osaurus tools upgrade   Обновляет установленные инструменты
              osaurus tools uninstall <tool_name>
                                      Удаляет инструмент
              osaurus tools verify    Проверяет целостность dylib установленных инструментов
              osaurus tools create <name> [--language swift|rust]
                                      Создаёт каркас проекта плагина v2
              osaurus tools package <plugin_id> <version> [dylib_path]
                                      Пакует плагин в zip (включая web/ и документацию)
              osaurus tools reload    Просит приложение заново просканировать инструменты
              osaurus tools rollback <plugin_id>
                                      Откатывает инструмент к предыдущей версии
              osaurus tools dev <plugin_id> [--web-proxy <url>]
                                      Режим разработки с горячей перезагрузкой и необязательным веб-прокси
              osaurus manifest extract <dylib>
                                      Извлекает JSON-манифест из собранного плагина
              osaurus bundle load <path.mcpb> [--name "Display Name"]
                                      Загружает и запускает MCP Bundle (.mcpb)
              osaurus help            Показывает эту справку

            """
        print(usage)
    }
}
