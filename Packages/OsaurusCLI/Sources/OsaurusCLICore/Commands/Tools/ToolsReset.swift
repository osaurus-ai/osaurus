//
//  ToolsReset.swift
//  osaurus
//
//  Resets plugin state to recover from crashes, corrupted data, or stale caches.
//

import Foundation
import OsaurusRepository

public struct ToolsReset {
    public static func execute(args: [String]) {
        let flags = Set(args)
        let resetPlugins = flags.contains("--plugins") || flags.contains("--all")
        let resetAll = flags.contains("--all")
        let fm = FileManager.default

        let registryClone = ToolsPaths.pluginSpecsRoot().appendingPathComponent("central", isDirectory: true)
        if fm.fileExists(atPath: registryClone.path) {
            do {
                try fm.removeItem(at: registryClone)
                print("Кэш реестра плагинов сброшен")
            } catch {
                fputs("Предупреждение: не удалось удалить кэш реестра: \(error)\n", stderr)
            }
        }

        let toolsRoot = ToolsPaths.toolsRootDirectory()
        for name in [".quarantine", ".currently_loading"] {
            let url = toolsRoot.appendingPathComponent(name, isDirectory: false)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
                print("Очищено \(name)")
            }
        }

        if resetPlugins {
            if let entries = try? fm.contentsOfDirectory(
                at: toolsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                var count = 0
                for entry in entries where entry.hasDirectoryPath {
                    try? fm.removeItem(at: entry)
                    count += 1
                }
                print("Удалено \(count) установленных плагинов")
            }
        }

        if resetAll {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "LaunchGuard.startupInProgress")
            defaults.removeObject(forKey: "LaunchGuard.consecutiveCrashCount")
            defaults.synchronize()
            print("Состояние восстановления после сбоев сброшено")
        }

        AppControl.postDistributedNotification(name: "com.dinoki.osaurus.control.toolsReload", userInfo: [:])
        print("Готово. Перезапустите Osaurus, чтобы применить изменения.")
        exit(EXIT_SUCCESS)
    }
}
