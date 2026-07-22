//
//  ToolsVerify.swift
//  osaurus
//
//  Command to verify installed tools by checking SHA256 hashes against receipt data.
//

import Foundation
import CryptoKit
import OsaurusRepository

public struct ToolsVerify {
    struct Report {
        var lines: [String] = []
        var failures: Int = 0

        mutating func ok(_ message: String) {
            lines.append("OK  \(message)")
        }

        mutating func fail(_ message: String) {
            lines.append("FAIL  \(message)")
            failures += 1
        }
    }

    public static func execute(args: [String]) {
        let root = PluginInstallManager.toolsRootDirectory()
        guard FileManager.default.fileExists(atPath: root.path) else {
            print("(no tools installed)")
            exit(EXIT_SUCCESS)
        }
        let report = verifyInstalledTools(root: root)
        if report.lines.isEmpty {
            print("(no tools installed)")
        } else {
            for line in report.lines {
                print(line)
            }
        }
        exit(report.failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    /// Verifies every installed plugin version under `root`. Any missing,
    /// unreadable, or malformed receipt/dylib is a FAILURE — a broken install
    /// must not verify clean just because the evidence of the breakage is the
    /// file that cannot be read.
    static func verifyInstalledTools(root: URL) -> Report {
        let fm = FileManager.default
        var report = Report()
        guard let pluginDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return report
        }
        for pluginDir in pluginDirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where pluginDir.hasDirectoryPath {
            let pluginId = pluginDir.lastPathComponent
            let versionsToCheck: [URL]
            let currentLink = pluginDir.appendingPathComponent("current")
            if let dest = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) {
                let target = pluginDir.appendingPathComponent(dest, isDirectory: true)
                guard fm.fileExists(atPath: target.path) else {
                    report.fail("\(pluginId)  'current' symlink points to missing version \(dest)")
                    continue
                }
                versionsToCheck = [target]
            } else {
                versionsToCheck =
                    (try? fm.contentsOfDirectory(at: pluginDir, includingPropertiesForKeys: nil))?.filter {
                        $0.hasDirectoryPath
                    } ?? []
            }
            for vdir in versionsToCheck.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                verifyVersionDirectory(vdir, pluginId: pluginId, report: &report)
            }
        }
        return report
    }

    private static func verifyVersionDirectory(_ vdir: URL, pluginId: String, report: inout Report) {
        let fm = FileManager.default
        let versionName = vdir.lastPathComponent
        let receiptURL = vdir.appendingPathComponent("receipt.json")

        guard fm.fileExists(atPath: receiptURL.path) else {
            report.fail("\(pluginId)@\(versionName)  receipt.json missing")
            return
        }
        guard let rdata = try? Data(contentsOf: receiptURL) else {
            report.fail("\(pluginId)@\(versionName)  receipt.json unreadable")
            return
        }
        guard let receipt = try? JSONDecoder().decode(PluginReceipt.self, from: rdata) else {
            report.fail("\(pluginId)@\(versionName)  receipt.json malformed")
            return
        }

        let dylibURL = vdir.appendingPathComponent(receipt.dylib_filename)
        guard fm.fileExists(atPath: dylibURL.path) else {
            report.fail("\(receipt.plugin_id)@\(receipt.version)  \(receipt.dylib_filename) missing")
            return
        }
        guard let dylibData = try? Data(contentsOf: dylibURL) else {
            report.fail("\(receipt.plugin_id)@\(receipt.version)  \(receipt.dylib_filename) unreadable")
            return
        }
        let digest = CryptoKit.SHA256.hash(data: dylibData)
        let sha = Data(digest).map { String(format: "%02x", $0) }.joined()
        if sha.lowercased() == receipt.dylib_sha256.lowercased() {
            report.ok("\(receipt.plugin_id)@\(receipt.version)  \(receipt.dylib_filename)")
        } else {
            report.fail("\(receipt.plugin_id)@\(receipt.version)  expected \(receipt.dylib_sha256) got \(sha)")
        }
    }
}
