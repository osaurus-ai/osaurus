//
//  ModelPickerDebugLog.swift
//  osaurus
//
//  TEMPORARY instrumentation for the model picker's dead hover on trailing
//  rows. Strip before any PR.
//

#if DEBUG
    import Foundation

    /// Appends timestamped lines to `<repo>/tmp/model-picker-hover-debug.log`
    /// (override with env `OSAURUS_MODEL_PICKER_DEBUG_LOG`). Writes hop to a
    /// serial utility queue so logging never touches the main thread's I/O.
    enum ModelPickerDebugLog {
        private static let queue = DispatchQueue(label: "ai.osaurus.modelpicker.debuglog", qos: .utility)

        private static let url: URL = {
            if let override = ProcessInfo.processInfo.environment["OSAURUS_MODEL_PICKER_DEBUG_LOG"],
                !override.isEmpty
            {
                return URL(fileURLWithPath: override)
            }
            // #filePath → <repo>/Packages/OsaurusCore/Views/Model/ModelPickerDebugLog.swift
            var root = URL(fileURLWithPath: #filePath)
            for _ in 0 ..< 5 { root.deleteLastPathComponent() }
            return root.appendingPathComponent("tmp").appendingPathComponent("model-picker-hover-debug.log")
        }()

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()

        static func log(_ message: @autoclosure () -> String) {
            let text = message()
            let now = Date()
            queue.async {
                let line = "\(formatter.string(from: now)) \(text)\n"
                guard let data = line.data(using: .utf8) else { return }
                let fm = FileManager.default
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: url)
                }
            }
        }
    }
#endif
