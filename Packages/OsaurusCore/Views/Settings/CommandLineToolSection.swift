//
//  CommandLineToolSection.swift
//  osaurus
//
//  "Command Line Tool" card on Developer Tools → Server → Overview. Installs
//  the `osaurus` CLI into the user's PATH via a symlink to the embedded
//  binary. Lived on the General tab until the settings cleanup moved every
//  developer-facing control under Developer Tools.
//

import AppKit
import SwiftUI

struct CommandLineToolSection: View {
    @Environment(\.theme) private var theme

    @State private var installMessage: String? = nil
    @State private var installSucceeded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Command Line Tool", bundle: .module)
            } icon: {
                Image(systemName: "apple.terminal")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(theme.primaryText)

            Text(
                "Install the `osaurus` CLI into your PATH for terminal access. If installed to ~/.local/bin, make sure that folder is in your PATH.",
                bundle: .module
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button(action: installCLI) {
                    Text("Install CLI", bundle: .module)
                }
                .buttonStyle(SettingsButtonStyle())
                .localizedHelp("Create a symlink to the embedded CLI")

                if let message = installMessage {
                    HStack(spacing: 6) {
                        Image(
                            systemName: installSucceeded
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 12))
                        Text(message)
                            .font(.system(size: 11))
                            .lineLimit(2)
                    }
                    .foregroundColor(installSucceeded ? theme.successColor : theme.warningColor)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.secondaryBackground)
        )
        .settingsLandingAnchor("server.cli")
    }
}

// MARK: - Install Helper

extension CommandLineToolSection {
    private func installCLI() {
        let fm = FileManager.default

        guard let cliURL = resolveCLIExecutableURL() else {
            installSucceeded = false
            installMessage = "CLI not found. Build the app with 'make app' or install via release DMG."
            return
        }

        // Candidate target directories. /opt/homebrew/bin is intentionally
        // NOT a candidate: it's a directory Homebrew owns and manages, and
        // Osaurus isn't distributed via a Homebrew formula — its presence
        // on a user's machine for unrelated packages isn't a reason for
        // this app to write into it. See osaurus-ai/osaurus#2137.
        let usrLocalBin = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        let userLocalBin = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)

        if tryInstall(cliURL: cliURL, into: usrLocalBin) {
            installSucceeded = true
            installMessage = "Installed to \(usrLocalBin.appendingPathComponent("osaurus").path)"
            return
        }

        // Fallback to user-local bin
        do {
            try fm.createDirectory(at: userLocalBin, withIntermediateDirectories: true)
        } catch {
            installSucceeded = false
            installMessage = "Failed to prepare ~/.local/bin (\(error.localizedDescription))"
            return
        }

        if tryInstall(cliURL: cliURL, into: userLocalBin) {
            let linkPath = userLocalBin.appendingPathComponent("osaurus").path
            let inPath = isDirInPATH(userLocalBin.path)
            installSucceeded = true
            installMessage =
                inPath
                ? "Installed to \(linkPath)"
                : "Installed to \(linkPath). Add to PATH."
            return
        }

        installSucceeded = false
        installMessage = "Installation failed. Try: scripts/install_cli_symlink.sh"
    }

    private func resolveCLIExecutableURL() -> URL? {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL

        // 1. Prefer embedded CLI in Helpers (production build via 'make app')
        let helpers = appURL.appendingPathComponent("Contents/Helpers/osaurus", isDirectory: false)
        if fm.fileExists(atPath: helpers.path), fm.isExecutableFile(atPath: helpers.path) {
            return helpers
        }

        // 2. Try MacOS folder (legacy or alternative embedding)
        let macOS = appURL.appendingPathComponent("Contents/MacOS/osaurus", isDirectory: false)
        if fm.fileExists(atPath: macOS.path), fm.isExecutableFile(atPath: macOS.path) {
            return macOS
        }

        // 3. Development: try the build Products directory
        let productsDir = appURL.deletingLastPathComponent()

        let debugCLI = productsDir.appendingPathComponent("osaurus-cli", isDirectory: false)
        if fm.fileExists(atPath: debugCLI.path), fm.isExecutableFile(atPath: debugCLI.path) {
            return debugCLI
        }

        let debugOsaurus = productsDir.appendingPathComponent("osaurus", isDirectory: false)
        if fm.fileExists(atPath: debugOsaurus.path), fm.isExecutableFile(atPath: debugOsaurus.path) {
            return debugOsaurus
        }

        // Check Release folder
        let releaseDir = productsDir.deletingLastPathComponent().appendingPathComponent("Release")
        let releaseCLI = releaseDir.appendingPathComponent("osaurus-cli", isDirectory: false)
        if fm.fileExists(atPath: releaseCLI.path), fm.isExecutableFile(atPath: releaseCLI.path) {
            return releaseCLI
        }

        let releaseOsaurus = releaseDir.appendingPathComponent("osaurus", isDirectory: false)
        if fm.fileExists(atPath: releaseOsaurus.path), fm.isExecutableFile(atPath: releaseOsaurus.path) {
            return releaseOsaurus
        }

        // 4. Check inside Release app bundle's Helpers folder
        let releaseAppHelpers =
            releaseDir
            .appendingPathComponent("osaurus.app/Contents/Helpers/osaurus", isDirectory: false)
        if fm.fileExists(atPath: releaseAppHelpers.path), fm.isExecutableFile(atPath: releaseAppHelpers.path) {
            return releaseAppHelpers
        }

        // 5. Check inside Release app bundle's MacOS folder
        let releaseAppMacOS =
            releaseDir
            .appendingPathComponent("osaurus.app/Contents/MacOS/osaurus", isDirectory: false)
        if fm.fileExists(atPath: releaseAppMacOS.path), fm.isExecutableFile(atPath: releaseAppMacOS.path) {
            return releaseAppMacOS
        }

        return nil
    }

    private func tryInstall(cliURL: URL, into dir: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }

        let linkURL = dir.appendingPathComponent("osaurus")

        // If an entry exists, replace only if it's a symlink
        if fm.fileExists(atPath: linkURL.path) {
            do {
                _ = try fm.destinationOfSymbolicLink(atPath: linkURL.path)
                // It's a symlink – remove and replace
                try? fm.removeItem(at: linkURL)
            } catch {
                // Not a symlink (likely a real file); do not overwrite
                return false
            }
        }

        do {
            try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: cliURL.path)
            return true
        } catch {
            return false
        }
    }

    private func isDirInPATH(_ dir: String) -> Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return path.split(separator: ":").map(String.init).contains { $0 == dir }
    }
}
