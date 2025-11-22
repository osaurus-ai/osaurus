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
    public static func execute(args: [String]) {
        let fm = FileManager.default
        let root = PluginInstallManager.toolsRootDirectory()
        guard let pluginDirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            print("(no tools installed)")
            exit(EXIT_SUCCESS)
        }
        var failures = 0
        for pluginDir in pluginDirs where pluginDir.hasDirectoryPath {
            let versionsToCheck: [URL]
            let currentLink = pluginDir.appendingPathComponent("current")
            if let dest = try? fm.destinationOfSymbolicLink(atPath: currentLink.path) {
                versionsToCheck = [pluginDir.appendingPathComponent(dest, isDirectory: true)]
            } else {
                versionsToCheck =
                    (try? fm.contentsOfDirectory(at: pluginDir, includingPropertiesForKeys: nil))?.filter {
                        $0.hasDirectoryPath
                    } ?? []
            }
            for vdir in versionsToCheck {
                let receiptURL = vdir.appendingPathComponent("receipt.json")
                guard let rdata = try? Data(contentsOf: receiptURL),
                    let receipt = try? JSONDecoder().decode(PluginReceipt.self, from: rdata)
                else {
                    continue
                }
                let dylibURL = vdir.appendingPathComponent(receipt.dylib_filename)
                guard let dylibData = try? Data(contentsOf: dylibURL) else { continue }
                let digest = CryptoKit.SHA256.hash(data: dylibData)
                let sha = Data(digest).map { String(format: "%02x", $0) }.joined()
                if sha.lowercased() == receipt.dylib_sha256.lowercased() {
                    print("OK  \(receipt.plugin_id)@\(receipt.version)  \(receipt.dylib_filename)")
                } else {
                    print("FAIL  \(receipt.plugin_id)@\(receipt.version)  expected \(receipt.dylib_sha256) got \(sha)")
                    failures += 1
                }
            }
        }
        exit(failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
