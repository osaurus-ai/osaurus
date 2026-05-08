//
//  ManifestCommand.swift
//  osaurus
//
//  Main command router for manifest subcommands (extract).
//

import Foundation

public struct ManifestCommand: Command {
    public static let name = "manifest"

    public static func execute(args: [String]) async {
        guard let sub = args.first else {
            fputs(
                "Отсутствует подкоманда manifest. Используйте одну из: extract\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "extract":
            ManifestExtract.execute(args: rest)
        default:
            fputs("Неизвестная подкоманда manifest: \(sub)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
