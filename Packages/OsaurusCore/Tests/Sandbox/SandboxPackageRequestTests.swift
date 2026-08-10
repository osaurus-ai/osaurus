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
