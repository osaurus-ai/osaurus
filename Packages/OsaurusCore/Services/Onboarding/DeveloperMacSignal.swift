//
//  DeveloperMacSignal.swift
//  osaurus
//
//  Whether this Mac belongs to a developer: Xcode is installed, the command
//  line tools are, or there is a git configuration. Decides whether the
//  first run creates Builder and installs Repo Digest. Looks for files
//  only; it never runs `git` or `xcode-select`, which can raise the
//  command line tools install dialog.
//

import AppKit
import Foundation

public enum DeveloperMacSignal {
    static let xcodeBundleIdentifier = "com.apple.dt.Xcode"
    static let commandLineToolsPath = "/Library/Developer/CommandLineTools"
    static let gitConfigName = ".gitconfig"

    public struct Probe: Sendable {
        var appInstalled: @Sendable (String) -> Bool
        var fileExists: @Sendable (String) -> Bool
        var homeDirectory: String

        public static let live = Probe(
            appInstalled: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil },
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }

    public static func isDeveloperMac(probe: Probe = .live) -> Bool {
        probe.appInstalled(xcodeBundleIdentifier)
            || probe.fileExists(commandLineToolsPath)
            || probe.fileExists((probe.homeDirectory as NSString).appendingPathComponent(gitConfigName))
    }
}
