//
//  ShellCommandRiskScanner.swift
//  osaurus
//
//  Reads a shell command the way the approval sheet needs it: what kind of
//  action it is ("Run a Python script", "Install Python packages") and
//  which risk signals it carries (deletes files, uses admin rights,
//  downloads code, reaches this Mac). Pure and synchronous so the full
//  matrix is unit tested.
//
//  This is a reading aid for the person deciding, not a policy gate:
//  nothing is allowed or refused from it. It is escalate-biased. A command
//  it cannot fully read (command substitution, `eval`, a pipe into a shell)
//  reports that as a signal of its own, so the sheet never calls a check
//  clean for something it could not see.
//

import Foundation

enum ShellCommandRiskScanner {

    // MARK: - Vocabulary

    enum Signal: String, CaseIterable, Sendable {
        case deletesFiles
        case usesAdminRights
        case downloads
        case changesMac
        case runsInBackground
        case uncheckable
    }

    /// What a command is, for the sheet's title.
    enum Action: Equatable, Sendable {
        case installPythonPackages
        case installNodePackages
        case installSystemPackages
        case runPythonScript
        case runPythonCode
        case runNodeScript
        case shellCommand
    }

    /// Where downloaded code comes from, for the signal's explanation.
    enum DownloadSource: Equatable, Sendable {
        case pypi
        case npm
        case systemPackages
        case gitRepository
        case web
        case otherPackages
    }

    struct Finding: Equatable, Sendable {
        let signal: Signal
        let title: String
        let detail: String
    }

    struct Report: Equatable, Sendable {
        let findings: [Finding]
        /// The checks that came back clean, as one sentence ("No file
        /// deletion, admin rights, or downloads"). Nil when nothing came back
        /// clean or the command could not be fully read.
        let cleanSummary: String?
    }

    /// One simple command: its program (basename, lowercased) and arguments.
    struct SimpleCommand: Equatable, Sendable {
        let program: String
        let arguments: [String]
        /// Reached through a pipe (`… | sh`).
        let isPipeTarget: Bool
    }

    // MARK: - Scan

    /// - Parameters:
    ///   - surface: where the command runs. A host surface is the
    ///     "Runs on your Mac" signal; nil skips that check.
    ///   - networkAvailable: false when the sandbox has no internet, which
    ///     turns a download into a note that it will fail.
    ///   - background: the call asked to run detached.
    static func scan(
        command: String,
        surface: ToolExecutionSurface?,
        networkAvailable: Bool = true,
        background: Bool = false
    ) -> Report {
        let parsed = parse(command)
        let commands = parsed.commands.flatMap(unwrapped)
        var findings: [Finding] = []

        if commands.contains(where: deletes) {
            findings.append(
                Finding(
                    signal: .deletesFiles, title: L("Deletes files"),
                    detail: surface == .nativeHost
                        ? L("Removes files or folders on your Mac. Deleted files don't go to the Trash.")
                        : L("Removes files or folders in the sandbox.")))
        }
        if commands.contains(where: { adminPrograms.contains($0.program) }) {
            findings.append(
                Finding(
                    signal: .usesAdminRights, title: L("Uses admin rights"),
                    detail: L("Asks to run part of the command as an administrator (root).")))
        }
        let sources = downloadSources(commands)
        if !sources.isEmpty {
            findings.append(downloadFinding(sources, surface: surface, networkAvailable: networkAvailable))
        }
        if surface == .nativeHost {
            findings.append(
                Finding(
                    signal: .changesMac, title: L("Runs on your Mac"),
                    detail: L("Not sandboxed. It has your normal access to files, apps, and processes.")))
        }
        if background {
            findings.append(
                Finding(
                    signal: .runsInBackground, title: L("Keeps running in the background"),
                    detail: L("Starts a process that keeps running after this step until it is stopped.")))
        }
        let uncheckable = parsed.hasOpaqueSyntax || commands.contains(where: runsOpaqueCode)
        if uncheckable {
            findings.append(
                Finding(
                    signal: .uncheckable, title: L("Couldn't fully check this command"),
                    detail: L("Part of it is built while it runs, so the app can't see everything it will do. Read the full command before you approve.")))
        }

        let found = Set(findings.map(\.signal))
        return Report(
            findings: findings,
            cleanSummary: uncheckable
                ? nil
                : cleanSummary(
                    deletes: found.contains(.deletesFiles),
                    admin: found.contains(.usesAdminRights),
                    downloads: found.contains(.downloads)))
    }

    /// One sentence naming the checks that came back clean. Spelled out per
    /// combination so each language can phrase the list naturally.
    private static func cleanSummary(deletes: Bool, admin: Bool, downloads: Bool) -> String? {
        switch (deletes, admin, downloads) {
        case (false, false, false): L("No file deletion, admin rights, or downloads")
        case (false, false, true): L("No file deletion or admin rights")
        case (false, true, false): L("No file deletion or downloads")
        case (true, false, false): L("No admin rights or downloads")
        case (false, true, true): L("No file deletion")
        case (true, false, true): L("No admin rights")
        case (true, true, false): L("No downloads")
        case (true, true, true): nil
        }
    }

    /// The kind of action a command performs, judged by its programs.
    /// Installs win over running, since they are what the person most needs
    /// to recognise.
    static func action(for command: String) -> Action {
        let commands = parse(command).commands.flatMap(unwrapped)
        let sources = downloadSources(commands)
        if sources.contains(.pypi) { return .installPythonPackages }
        if sources.contains(.npm) { return .installNodePackages }
        if sources.contains(.systemPackages) { return .installSystemPackages }
        guard let main = commands.first(where: { !setupPrograms.contains($0.program) }) else { return .shellCommand }
        if isPython(main.program) {
            if main.arguments.first == "-c" { return .runPythonCode }
            if main.arguments.first.map(isScriptPath) == true { return .runPythonScript }
            if main.arguments.first == "-m" { return .runPythonScript }
            return .shellCommand
        }
        if main.program == "node", main.arguments.first.map(isScriptPath) == true { return .runNodeScript }
        return .shellCommand
    }

    // MARK: - Program tables

    private static let adminPrograms: Set<String> = ["sudo", "su", "doas", "pkexec"]

    private static let deletingPrograms: Set<String> = ["rm", "rmdir", "unlink", "shred", "srm", "truncate"]

    /// Programs that only prepare the environment, skipped when judging what
    /// a chain of commands is for (`cd x && python3 main.py`).
    private static let setupPrograms: Set<String> = [
        "cd", "export", "set", "source", ".", "mkdir", "echo", "true", "pushd", "popd", "ls", "pwd",
    ]

    /// Wrappers whose first non-option argument is the real program.
    private static let wrapperPrograms: Set<String> = [
        "sudo", "doas", "env", "nohup", "time", "nice", "timeout", "xargs", "exec", "command", "stdbuf",
    ]

    /// Shell keywords that can precede a command in a compound statement.
    private static let shellKeywords: Set<String> = [
        "do", "then", "else", "elif", "if", "while", "until", "!", "{", "}", "done", "fi", "esac",
    ]

    private static let shellInterpreters: Set<String> = ["sh", "bash", "zsh", "dash", "ash", "ksh", "fish"]

    private static func isPython(_ program: String) -> Bool {
        program == "python" || program.hasPrefix("python3") || program == "python2"
    }

    private static func isScriptPath(_ argument: String) -> Bool {
        !argument.hasPrefix("-")
    }

    // MARK: - Signal rules

    private static func deletes(_ command: SimpleCommand) -> Bool {
        if deletingPrograms.contains(command.program) { return true }
        switch command.program {
        case "find":
            if command.arguments.contains("-delete") { return true }
            for (index, argument) in command.arguments.enumerated() where argument == "-exec" || argument == "-execdir" {
                if let next = command.arguments.dropFirst(index + 1).first,
                    deletingPrograms.contains(basename(next))
                {
                    return true
                }
            }
            return false
        case "git":
            let sub = subcommand(of: command)
            return sub == "clean" || sub == "rm"
        default:
            return false
        }
    }

    private static func runsOpaqueCode(_ command: SimpleCommand) -> Bool {
        if command.program == "eval" { return true }
        if command.isPipeTarget, shellInterpreters.contains(command.program) || isPython(command.program) {
            return true
        }
        return false
    }

    private static func downloadSources(_ commands: [SimpleCommand]) -> [DownloadSource] {
        var sources: [DownloadSource] = []
        func add(_ source: DownloadSource) { if !sources.contains(source) { sources.append(source) } }
        for command in commands {
            let sub = subcommand(of: command)
            switch command.program {
            case "pip", "pip3", "pipx":
                if sub == "install" || sub == "download" { add(.pypi) }
            case "uv":
                if sub == "pip", command.arguments.contains("install") { add(.pypi) }
                if sub == "add" || sub == "sync" || sub == "tool" { add(.pypi) }
            case "uvx":
                add(.pypi)
            case let program where isPython(program):
                if command.arguments.first == "-m", command.arguments.dropFirst().first == "pip",
                    command.arguments.contains("install")
                {
                    add(.pypi)
                }
            case "npm", "pnpm", "yarn", "bun":
                if ["install", "i", "add", "ci"].contains(sub) || (command.program == "yarn" && sub == nil) {
                    add(.npm)
                }
            case "npx", "bunx", "pnpx":
                add(.npm)
            case "apk", "apt", "apt-get", "brew", "dnf", "yum":
                if sub == "add" || sub == "install" { add(.systemPackages) }
            case "gem", "cargo", "go":
                if sub == "install" || sub == "add" || sub == "get" { add(.otherPackages) }
            case "git":
                if sub == "clone" || sub == "pull" || sub == "fetch" { add(.gitRepository) }
            case "curl", "wget":
                add(.web)
            default:
                break
            }
        }
        return sources
    }

    private static func downloadFinding(
        _ sources: [DownloadSource], surface: ToolExecutionSurface?, networkAvailable: Bool
    ) -> Finding {
        guard networkAvailable else {
            return Finding(
                signal: .downloads, title: L("Tries to download from the internet"),
                detail: L("This sandbox has no internet access, so the download will fail."))
        }
        let onMac = surface == .nativeHost
        let details = sources.prefix(2).map { source -> String in
            switch source {
            case .pypi:
                return onMac
                    ? L("Installs packages from PyPI onto your Mac. Check the names are what you expect.")
                    : L("Installs packages from PyPI into the sandbox. Check the names are what you expect.")
            case .npm:
                return onMac
                    ? L("Installs packages from the npm registry onto your Mac. Check the names are what you expect.")
                    : L("Installs packages from the npm registry into the sandbox. Check the names are what you expect.")
            case .systemPackages:
                return onMac ? L("Installs system packages onto your Mac.") : L("Installs system packages into the sandbox.")
            case .otherPackages:
                return onMac
                    ? L("Installs packages from a public registry onto your Mac.")
                    : L("Installs packages from a public registry into the sandbox.")
            case .gitRepository:
                return onMac
                    ? L("Copies code from a git repository onto your Mac.")
                    : L("Copies code from a git repository into the sandbox.")
            case .web:
                return onMac
                    ? L("Fetches files from the internet onto your Mac. Check the address is one you trust.")
                    : L("Fetches files from the internet into the sandbox. Check the address is one you trust.")
            }
        }
        return Finding(
            signal: .downloads, title: L("Downloads code from the internet"), detail: details.joined(separator: " "))
    }

    // MARK: - Parsing

    struct Parsed: Equatable, Sendable {
        let commands: [SimpleCommand]
        /// `$(…)`, backticks, or process substitution outside single quotes.
        let hasOpaqueSyntax: Bool
    }

    /// Splits a command line into simple commands on `;`, `&&`, `||`, `|`,
    /// `&`, newlines and parentheses, honouring quotes and backslashes.
    static func parse(_ command: String) -> Parsed {
        var commands: [SimpleCommand] = []
        var words: [String] = []
        var word = ""
        var hasWord = false
        var opaque = false
        var nextIsPipeTarget = false
        var quote: Character?
        var chars = Array(command)
        chars.append("\n")
        var index = 0

        func endWord() {
            if hasWord { words.append(word) }
            word = ""
            hasWord = false
        }
        func endCommand(pipe: Bool) {
            endWord()
            if let simple = simpleCommand(words, isPipeTarget: nextIsPipeTarget) { commands.append(simple) }
            words = []
            nextIsPipeTarget = pipe
        }

        while index < chars.count {
            let c = chars[index]
            let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
            if let open = quote {
                if c == open {
                    quote = nil
                } else if open == "\"", c == "\\", let next {
                    word.append(next)
                    index += 1
                } else {
                    if open == "\"", c == "`" || (c == "$" && next == "(") { opaque = true }
                    word.append(c)
                }
                index += 1
                continue
            }
            switch c {
            case "'", "\"":
                quote = c
                hasWord = true
            case "\\":
                if let next, next != "\n" {
                    word.append(next)
                    hasWord = true
                }
                index += 1
            case "`":
                opaque = true
                endCommand(pipe: false)
            case "$" where next == "(":
                opaque = true
                endCommand(pipe: false)
                index += 1
            case " ", "\t":
                endWord()
            case "\n", ";", "(", ")":
                endCommand(pipe: false)
            case "&":
                if next == "&" { index += 1 } else if next == ">" { break }
                endCommand(pipe: false)
            case "|":
                if next == "|" {
                    index += 1
                    endCommand(pipe: false)
                } else {
                    endCommand(pipe: true)
                }
            case ">", "<":
                if next == "(" {
                    // Process substitution runs a command the line hides.
                    opaque = true
                    endCommand(pipe: false)
                    index += 2
                    continue
                }
                // Redirection: drop the operator, its target, and a file
                // descriptor written against it (`2>`).
                if hasWord, !word.isEmpty, word.allSatisfy(\.isNumber) {
                    word = ""
                    hasWord = false
                }
                endWord()
                if next == ">" || next == "&" { index += 1 }
                index += 1
                while index < chars.count, chars[index] == " " { index += 1 }
                while index < chars.count, !" \t\n;|&()".contains(chars[index]) { index += 1 }
                continue
            default:
                word.append(c)
                hasWord = true
            }
            index += 1
        }
        if quote != nil { opaque = true }
        return Parsed(commands: commands, hasOpaqueSyntax: opaque)
    }

    private static func simpleCommand(_ words: [String], isPipeTarget: Bool) -> SimpleCommand? {
        var remaining = words[...]
        while let first = remaining.first,
            shellKeywords.contains(first) || isAssignment(first) || first == "for" || first == "case"
        {
            if first == "for" || first == "case" { return nil }
            remaining = remaining.dropFirst()
        }
        guard let program = remaining.first else { return nil }
        return SimpleCommand(program: basename(program), arguments: Array(remaining.dropFirst()), isPipeTarget: isPipeTarget)
    }

    /// The command itself plus, for wrappers (`sudo`, `env`, `xargs`, …),
    /// the command they run.
    private static func unwrapped(_ command: SimpleCommand) -> [SimpleCommand] {
        guard wrapperPrograms.contains(command.program) else { return [command] }
        var rest = command.arguments[...]
        while let first = rest.first, first.hasPrefix("-") || isAssignment(first) || Double(first) != nil {
            rest = rest.dropFirst()
        }
        guard let inner = rest.first else { return [command] }
        let wrapped = SimpleCommand(
            program: basename(inner), arguments: Array(rest.dropFirst()), isPipeTarget: command.isPipeTarget)
        return [command] + unwrapped(wrapped)
    }

    private static func subcommand(of command: SimpleCommand) -> String? {
        command.arguments.first { !$0.hasPrefix("-") }?.lowercased()
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func basename(_ program: String) -> String {
        (program.split(separator: "/").last.map(String.init) ?? program).lowercased()
    }
}
