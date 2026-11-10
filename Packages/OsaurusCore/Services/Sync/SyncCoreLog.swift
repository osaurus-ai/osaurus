//
//  SyncCoreLog.swift
//  osaurus
//
//  The sync core's own log records: session set-up, peers rejected, device
//  admission, held events. Without a listener the core logs nowhere, so why
//  an iPhone was never admitted, or why its session kept dropping, could not
//  be seen. Debug builds write them into tmp/osaurus.log beside the app's
//  lines, prefixed `[SyncCore]`; release builds send them to the unified log
//  (Console.app, subsystem `ai.osaurus.sync`).
//

import Foundation
import OsaurusSync

enum SyncCoreLog {
    /// Installs the listener. Logging is process-wide; call once at launch.
    static func start() {
        #if DEBUG
            SyncLogging.setHandler(level: .info) { record in
                let fields = record.formattedFields.isEmpty ? "" : " " + record.formattedFields
                ConsoleLogFile.append("[SyncCore] \(record.level) \(record.target): \(record.message)\(fields)")
            }
        #else
            SyncLogging.useOSLog(level: .info, subsystem: "ai.osaurus.sync")
        #endif
    }
}
