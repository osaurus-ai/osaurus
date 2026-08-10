//
//  IMessageSystemIntegrityProbe.swift
//  osaurus
//
//  Read-only diagnostics for the two system protections iMessage advanced
//  (private-API) actions require the operator to disable: System Integrity
//  Protection (SIP) and system-wide Library Validation.
//
//  This probe ONLY reads state. Osaurus never disables SIP or Library
//  Validation, and never runs a privileged command to change them. The setup
//  UI surfaces this state with an explicit security warning so the operator
//  makes the tradeoff themselves, in Recovery, outside Osaurus.
//

import Foundation

struct IMessageSystemIntegritySnapshot: Equatable, Sendable {
    /// nil when the state could not be determined (e.g. `csrutil` unavailable).
    var sipEnabled: Bool?
    var libraryValidationEnabled: Bool?
}

protocol IMessageSystemIntegrityProbing: Sendable {
    func snapshot() -> IMessageSystemIntegritySnapshot
}

#if os(macOS)

    struct IMessageSystemIntegrityProbe: IMessageSystemIntegrityProbing {
        func snapshot() -> IMessageSystemIntegritySnapshot {
            IMessageSystemIntegritySnapshot(
                sipEnabled: Self.readSIPEnabled(),
                libraryValidationEnabled: Self.readLibraryValidationEnabled()
            )
        }

        /// Parse `csrutil status`. Read-only. Returns nil if the tool is
        /// missing or the output can't be parsed.
        static func readSIPEnabled() -> Bool? {
            let csrutil = "/usr/bin/csrutil"
            guard FileManager.default.isExecutableFile(atPath: csrutil) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: csrutil)
            process.arguments = ["status"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let output = String(data: data, encoding: .utf8)?.lowercased() else { return nil }
            if output.contains("enabled") { return true }
            if output.contains("disabled") { return false }
            return nil
        }

        /// Read the system-wide Library Validation override plist. The known
        /// operator toggle is `DisableLibraryValidation` in
        /// `/Library/Preferences/com.apple.security.libraryvalidation.plist`.
        /// Absent/false means Library Validation is enabled (the default).
        static func readLibraryValidationEnabled() -> Bool? {
            let path = "/Library/Preferences/com.apple.security.libraryvalidation.plist"
            guard FileManager.default.fileExists(atPath: path) else {
                // No override file: Library Validation is on by default.
                return true
            }
            guard let dict = NSDictionary(contentsOfFile: path) else { return nil }
            if let disabled = dict["DisableLibraryValidation"] as? Bool {
                return !disabled
            }
            return true
        }
    }

#else

    struct IMessageSystemIntegrityProbe: IMessageSystemIntegrityProbing {
        func snapshot() -> IMessageSystemIntegritySnapshot {
            IMessageSystemIntegritySnapshot(sipEnabled: nil, libraryValidationEnabled: nil)
        }
    }

#endif
