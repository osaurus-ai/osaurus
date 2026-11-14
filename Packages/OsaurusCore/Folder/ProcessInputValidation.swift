import Foundation

/// Foundation raises an Objective-C exception for NUL-containing argument or
/// environment strings. Validate before launch so callers can recover normally.
enum ProcessInputValidation {
    enum InvalidInput: Error, LocalizedError, CustomStringConvertible, Equatable {
        case argument(Int)
        case environmentKey
        case environmentValue

        var errorDescription: String? { description }

        var description: String {
            switch self {
            case .argument(let index):
                return "Process argument at index \(index) contains a NUL character."
            case .environmentKey:
                return "Process environment key contains a NUL character."
            case .environmentValue:
                return "Process environment value contains a NUL character."
            }
        }
    }

    static func validate(_ process: Process) throws {
        for (index, argument) in (process.arguments ?? []).enumerated() {
            if argument.utf8.contains(0) { throw InvalidInput.argument(index) }
        }
        for (key, value) in process.environment ?? [:] {
            if key.utf8.contains(0) { throw InvalidInput.environmentKey }
            if value.utf8.contains(0) { throw InvalidInput.environmentValue }
        }
    }
}
