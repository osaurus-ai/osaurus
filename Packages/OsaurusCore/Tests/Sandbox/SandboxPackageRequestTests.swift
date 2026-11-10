import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct SandboxPackageRequestTests {
    @Test
    func acceptsVersionedAndScopedSpecifiersWithSafeShellEncoding() throws {
        let request = try SandboxPackageRequest.normalize([
            "requests[security]>=2.32",
            "@scope/pkg@^3",
            "author's-package",
        ])

        #expect(request.packages == [
            "requests[security]>=2.32",
            "@scope/pkg@^3",
            "author's-package",
        ])
        #expect(request.shellArguments.contains("'requests[security]>=2.32'"))
        #expect(request.shellArguments.contains("'@scope/pkg@^3'"))
        #expect(request.shellArguments.contains("'author'\"'\"'s-package'"))
    }

    @Test
    func rejectsEmptyControlAndOptionInjectionSpecifiers() {
        #expect(throws: SandboxPackageRequestError.empty) {
            try SandboxPackageRequest.normalize([])
        }
        #expect(throws: SandboxPackageRequestError.emptySpecifier(index: 0)) {
            try SandboxPackageRequest.normalize([" \n "])
        }
        #expect(throws: SandboxPackageRequestError.controlCharacter(index: 0)) {
            try SandboxPackageRequest.normalize(["safe\u{0000}unsafe"])
        }
        #expect(throws: SandboxPackageRequestError.optionInjection(index: 0)) {
            try SandboxPackageRequest.normalize(["--index-url=https://evil.example"])
        }
    }

    @Test
    func rejectsURLGitAndPathSpecifiers() {
        let refused = [
            "git+https://github.com/x/y.git", "https://example.com/pkg.tar.gz", "http://e.com/a", "file:./local",
            "github:user/repo", "user/repo", "./vendor/pkg", "/tmp/pkg", "~/pkg", "pkg.whl", "thing-1.0.tgz",
            "name @ https://example.com/name.zip", "foo@npm:bar", "@scope/name/extra", "@/name", "./x.apk",
        ]
        for spec in refused {
            #expect(throws: SandboxPackageRequestError.nonRegistrySource(index: 0), "\(spec)") {
                try SandboxPackageRequest.normalize([spec])
            }
        }
        for spec in ["yt-dlp", "numpy>=2", "requests[security]>=2.32", "@scope/pkg@^3", "ffmpeg", "py3-pip=24.0-r2"] {
            #expect(throws: Never.self, "\(spec)") { try SandboxPackageRequest.normalize([spec]) }
        }
        let dependency = WorkflowDependency(manager: .pip, packages: ["git+https://github.com/x/y.git"])
        #expect(dependency.issues.contains { $0.contains("URL, git repository, or file path") })
    }

    @Test
    func enforcesCountAndLengthBounds() {
        #expect(
            throws: SandboxPackageRequestError.tooMany(
                actual: SandboxPackageRequest.maximumPackageCount + 1,
                maximum: SandboxPackageRequest.maximumPackageCount
            )
        ) {
            try SandboxPackageRequest.normalize(
                Array(
                    repeating: "pkg",
                    count: SandboxPackageRequest.maximumPackageCount + 1
                )
            )
        }
        #expect(
            throws: SandboxPackageRequestError.tooLong(
                index: 0,
                maximum: SandboxPackageRequest.maximumSpecifierLength
            )
        ) {
            try SandboxPackageRequest.normalize([
                String(repeating: "a", count: SandboxPackageRequest.maximumSpecifierLength + 1)
            ])
        }
    }
}
