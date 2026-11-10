//
//  SandboxStepScope.swift
//  osaurus
//
//  What the sandbox commands of one workflow step run with, beyond the
//  identity's own setup. Python code steps bind the hosts their spec
//  declares, so every command the step runs reaches only those hosts
//  through the egress proxy (none when the list is empty), and the
//  secrets the step declares, which ride in the exec environment rather
//  than a file and are scrubbed from its output.
//

import Foundation

public enum SandboxStepScope {
    @TaskLocal public static var hosts: [String]?
    @TaskLocal public static var secrets: [String: String] = [:]

    /// The env variable carrying `secrets` as a JSON object.
    public static let secretsVariable = "OSAURUS_STEP_SECRETS"

    /// Env the step's commands get on top of the identity's.
    static var environment: [String: String] {
        guard !secrets.isEmpty,
            let data = try? JSONSerialization.data(withJSONObject: secrets, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return [:] }
        return [secretsVariable: json]
    }
}
