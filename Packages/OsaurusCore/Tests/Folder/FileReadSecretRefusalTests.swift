//
//  FileReadSecretRefusalTests.swift
//  osaurusTests
//
//  Pins the combined sandbox + host-read secret-file classifier. In
//  combined mode `file_read` refuses secret material inside the scoped
//  workspace (.env / private keys / credentials) so a poisoned file or a
//  steered instruction can't pull secrets into context and exfiltrate
//  them via the sandbox. These tests cover the classifier directly; the
//  task-local gating + per-session override live in `FileReadTool.execute`.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct FileReadSecretRefusalTests {

    private func isSecret(_ relativePath: String) -> Bool {
        let root = URL(fileURLWithPath: "/tmp/osaurus-secret-test")
        let fileURL = root.appendingPathComponent(relativePath)
        return FolderToolHelpers.isSecretPath(fileURL: fileURL)
    }

    @Test func refusesEnvAndKeysAndCredentials() {
        #expect(isSecret(".env"))
        #expect(isSecret("config/.env.production"))
        #expect(isSecret("certs/server.pem"))
        #expect(isSecret("server.key"))
        #expect(isSecret("keystore.p12"))
        #expect(isSecret(".npmrc"))
        #expect(isSecret(".netrc"))
        #expect(isSecret(".git/config"))
        #expect(isSecret(".ssh/id_rsa"))
        #expect(isSecret("home/.aws/credentials"))
        #expect(isSecret("id_ed25519"))
    }

    @Test func allowsOrdinarySourceAndPublicKeysAndTemplates() {
        #expect(!isSecret("README.md"))
        #expect(!isSecret("Sources/App.swift"))
        #expect(!isSecret("package.json"))
        // Public keys are safe to read.
        #expect(!isSecret(".ssh-notes/id_rsa.pub"))
        #expect(!isSecret("keys/server.pub"))
        // `.env` templates / samples are conventionally non-secret.
        #expect(!isSecret(".env.example"))
        #expect(!isSecret(".env.sample"))
        #expect(!isSecret("config/.env.template"))
    }
}
