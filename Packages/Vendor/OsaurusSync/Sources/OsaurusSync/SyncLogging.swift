import Foundation
import os

/// Routes the core's log records into the app. Logging is process-wide: one listener serves
/// every open `SyncCore`.
public enum SyncLogging {
    /// Sends records at `level` and more severe to the unified logging system, one category per
    /// core module. Messages are public; fields (abbreviated ids and counts) are hashed outside
    /// a debugger.
    public static func useOSLog(level: LogLevel = .info, subsystem: String = "ai.osaurus.sync") {
        setLogListener(level: level, listener: OSLogListener(subsystem: subsystem))
    }

    /// Calls `handler` for every record at `level` and more severe, on the core's log thread.
    public static func setHandler(level: LogLevel = .info, _ handler: @escaping @Sendable (LogRecord) -> Void) {
        setLogListener(level: level, listener: ClosureLogListener(handler))
    }

    public static func disable() {
        setLogListener(level: .info, listener: nil)
    }
}

extension LogRecord {
    /// The fields as `key=value` pairs, sorted by key.
    public var formattedFields: String {
        fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
    }
}

/// Forwards records to `os.Logger`.
public final class OSLogListener: LogListener, @unchecked Sendable {
    private let subsystem: String
    private var loggers: [String: Logger] = [:]
    private let lock = NSLock()

    public init(subsystem: String = "ai.osaurus.sync") {
        self.subsystem = subsystem
    }

    private func logger(for target: String) -> Logger {
        lock.lock()
        defer { lock.unlock() }
        if let l = loggers[target] { return l }
        let l = Logger(subsystem: subsystem, category: target)
        loggers[target] = l
        return l
    }

    public func onLog(record: LogRecord) {
        let logger = logger(for: record.target)
        let message = record.message
        let fields = record.formattedFields
        switch record.level {
        case .error:
            logger.error("\(message, privacy: .public) \(fields, privacy: .private(mask: .hash))")
        case .warn:
            logger.warning("\(message, privacy: .public) \(fields, privacy: .private(mask: .hash))")
        case .info:
            logger.info("\(message, privacy: .public) \(fields, privacy: .private(mask: .hash))")
        case .debug, .trace:
            logger.debug("\(message, privacy: .public) \(fields, privacy: .private(mask: .hash))")
        }
    }
}

final class ClosureLogListener: LogListener, @unchecked Sendable {
    let f: @Sendable (LogRecord) -> Void
    init(_ f: @escaping @Sendable (LogRecord) -> Void) { self.f = f }
    func onLog(record: LogRecord) { f(record) }
}
