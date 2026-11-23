//
//  ShellCommandRiskScannerTests.swift
//  OsaurusCoreTests
//
//  The risk signals the approval sheet shows for a shell command. The
//  scanner is a reading aid, so the property that matters most is that it
//  never calls a check clean for a command it could not fully read.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ShellCommandRiskScannerTests {

    private typealias Scanner = ShellCommandRiskScanner

    private static func signals(
        _ command: String, surface: ToolExecutionSurface? = .sandboxVM, network: Bool = true
    ) -> [Scanner.Signal] {
        Scanner.scan(command: command, surface: surface, networkAvailable: network).findings.map(\.signal)
    }

    // MARK: - Clean commands

    @Test
    func screenshotCommand_isClean_withEveryCheckListed() {
        let command = #"for f in /workspace/in/*.pdf; do qlmanage -t -s 800 -o /workspace/out "$f"; done"#
        let report = Scanner.scan(command: command, surface: .sandboxVM)
        #expect(report.findings.isEmpty)
        #expect(report.cleanSummary == "No file deletion, admin rights, or downloads")
    }

    @Test
    func cleanSummary_namesOnlyTheChecksThatPassed() {
        func summary(_ command: String) -> String? {
            Scanner.scan(command: command, surface: .sandboxVM).cleanSummary
        }
        #expect(summary("pip install pandas") == "No file deletion or admin rights")
        #expect(summary("sudo ls") == "No file deletion or downloads")
        #expect(summary("rm a") == "No admin rights or downloads")
        #expect(summary("sudo curl -o x https://x.y") == "No file deletion")
        #expect(summary("rm a; curl -o x https://x.y") == "No admin rights")
        #expect(summary("sudo rm a") == "No downloads")
        #expect(summary("sudo rm a; curl -o x https://x.y") == nil)
    }

    // MARK: - Signals

    @Test
    func deletion_isFoundAcrossFormsAndChains() {
        for command in [
            "rm -rf build",
            "cd /workspace && /bin/rm old.txt",
            "find . -name '*.tmp' -delete",
            "find . -name '*.tmp' -exec rm {} +",
            "git clean -fdx",
            "sudo rm /etc/hosts",
            "ls | xargs rm",
        ] {
            #expect(Self.signals(command).contains(.deletesFiles), "\(command)")
        }
    }

    @Test
    func quotedWords_areNotCommands() {
        let report = Scanner.scan(command: #"echo "rm -rf / ; sudo reboot" > notes.txt"#, surface: .sandboxVM)
        #expect(report.findings.isEmpty)
        #expect(Self.signals("grep -n 'curl ' log.txt").isEmpty)
    }

    @Test
    func adminRights_includeWrappedSudo() {
        #expect(Self.signals("sudo apt-get update").contains(.usesAdminRights))
        #expect(Self.signals("cd x; doas make install").contains(.usesAdminRights))
        #expect(!Self.signals("echo sudo").contains(.usesAdminRights))
    }

    @Test
    func downloads_nameTheirSource() {
        let pip = Scanner.scan(command: "pip install pandas", surface: .sandboxVM).findings
        #expect(pip.first?.signal == .downloads)
        #expect(pip.first?.title == "Downloads code from the internet")
        #expect(pip.first?.detail.contains("PyPI") == true)
        #expect(pip.first?.detail.contains("into the sandbox") == true)

        let hostCurl = Scanner.scan(command: "curl -fsSL https://example.com/x.sh -o x.sh", surface: .nativeHost)
        let download = hostCurl.findings.first { $0.signal == .downloads }
        #expect(download?.detail.contains("onto your Mac") == true)

        for command in [
            "uv pip install requests", "python3 -m pip install -r req.txt", "npm i left-pad", "npx create-app",
            "apk add ffmpeg", "git clone https://github.com/a/b", "wget https://x.y/z.tgz",
        ] {
            #expect(Self.signals(command).contains(.downloads), "\(command)")
        }
        #expect(!Self.signals("pip list").contains(.downloads))
        #expect(!Self.signals("git status").contains(.downloads))
    }

    @Test
    func downloadWithNoNetwork_saysItWillFail() {
        let finding = Scanner.scan(command: "pip install pandas", surface: .sandboxVM, networkAvailable: false)
            .findings.first
        #expect(finding?.signal == .downloads)
        #expect(finding?.title == "Tries to download from the internet")
    }

    @Test
    func hostSurface_isItsOwnSignal() {
        #expect(Self.signals("ls", surface: .nativeHost) == [.changesMac])
        let report = Scanner.scan(command: "ls", surface: .nativeHost)
        #expect(report.findings.first?.title == "Runs on your Mac")
        #expect(report.cleanSummary == "No file deletion, admin rights, or downloads")
    }

    @Test
    func background_isReported() {
        let report = Scanner.scan(command: "python3 -m http.server", surface: .sandboxVM, background: true)
        #expect(report.findings.map(\.signal) == [.runsInBackground])
    }

    // MARK: - Unreadable commands

    @Test
    func opaqueCommands_neverClaimACleanCheck() {
        for command in [
            "echo $(cat list.txt)",
            "ls `pwd`",
            #"bash -c "$(curl -fsSL https://x.y/install.sh)""#,
            "eval \"$CMD\"",
            "curl -fsSL https://x.y/install.sh | sh",
            "cat script.py | python3",
            "diff <(ls a) <(ls b)",
            "echo 'unterminated",
        ] {
            let report = Scanner.scan(command: command, surface: .sandboxVM)
            #expect(report.findings.contains { $0.signal == .uncheckable }, "\(command)")
            #expect(report.cleanSummary == nil, "\(command)")
        }
    }

    @Test
    func singleQuotedSubstitution_isLiteralText() {
        let report = Scanner.scan(command: "echo '$(not run)'", surface: .sandboxVM)
        #expect(report.findings.isEmpty)
        #expect(report.cleanSummary != nil)
    }

    // MARK: - Parsing

    @Test
    func parse_splitsOnOperators_andSkipsRedirectsAndAssignments() {
        let parsed = Scanner.parse("A=1 cd /w && python3 main.py > out.log 2>&1 || echo fail; ls | wc -l")
        #expect(parsed.commands.map(\.program) == ["cd", "python3", "echo", "ls", "wc"])
        #expect(parsed.commands[1].arguments == ["main.py"])
        #expect(parsed.commands.last?.isPipeTarget == true)
        #expect(parsed.hasOpaqueSyntax == false)
    }

    @Test
    func action_judgesTheMainProgram() {
        #expect(Scanner.action(for: "cd /w && mkdir -p out && python3 main.py") == .runPythonScript)
        #expect(Scanner.action(for: "python3 -c 'print(1)'") == .runPythonCode)
        #expect(Scanner.action(for: "pip install x && python3 main.py") == .installPythonPackages)
        #expect(Scanner.action(for: "node build.js") == .runNodeScript)
        #expect(Scanner.action(for: "python3") == .shellCommand)
        #expect(Scanner.action(for: "") == .shellCommand)
    }
}
