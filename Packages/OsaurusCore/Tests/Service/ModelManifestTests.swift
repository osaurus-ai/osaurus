import Foundation
import Testing

@testable import OsaurusCore

struct ModelManifestTests {
    @Test(arguments: ["0.25.0", "0.25.1", "1.0", "1", "0.25.0+build.7"])
    func compatibleHosts(host: String) throws {
        let manifest = try ModelManifest.decode(
            Data(#"{"required_osaurus_version":"0.25.0","model_version":"1","future_key":true}"#.utf8)
        )
        #expect(manifest.compatibilityFailure(hostVersion: host) == nil)
    }

    @Test(arguments: ["0.24.9", "0.25.0-rc.1", "0.1.999"])
    func refusesOldHosts(host: String) throws {
        let manifest = try ModelManifest.decode(
            Data(#"{"required_osaurus_version":"0.25.0","model_version":"1"}"#.utf8)
        )
        #expect(manifest.compatibilityFailure(hostVersion: host)?.reason == .requiresOsaurusUpdate)
    }

    @Test(arguments: ["", "dev", "1.bad", "1.0.0.0", "-1.0.0", "1.0.0-", "1.0.0+", "01.0.0"])
    func unknownHostNeverBypassesRequirement(host: String) throws {
        let manifest = try ModelManifest.decode(
            Data(#"{"required_osaurus_version":"0.25.0","model_version":"1"}"#.utf8)
        )
        #expect(manifest.compatibilityFailure(hostVersion: host)?.reason == .unknownOsaurusVersion)
    }

    @Test(arguments: [
        "[]", "null", "{", "{}", #"{"required_osaurus_version":"0.25.0"}"#, #"{"model_version":"1"}"#,
        #"{"model_version":1,"required_osaurus_version":"0.25.0"}"#,
        #"{"model_version":"v1","required_osaurus_version":"0.25.0"}"#,
        #"{"model_version":"-1","required_osaurus_version":"0.25.0"}"#,
        #"{"required_osaurus_version":"","model_version":"1"}"#,
        #"{"required_osaurus_version":"0.25.0-01","model_version":"1"}"#,
        #"{"required_osaurus_version":25,"model_version":"1"}"#,
    ])
    func malformedPresentManifestsAreErrors(json: String) {
        #expect(throws: ModelManifest.Failure.self) { try ModelManifest.decode(Data(json.utf8)) }
    }

    @Test func semanticPrecedenceAndRevisionComparison() throws {
        let ordered = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11",
            "1.0.0-rc.1", "1.0.0",
        ]
        for (lower, upper) in zip(ordered, ordered.dropFirst()) {
            #expect(try #require(ModelManifest.Version(lower)) < #require(ModelManifest.Version(upper)))
        }
        #expect(ModelManifest.Version("1.0.0+first") == ModelManifest.Version("1.0.0+second"))
        func manifest(_ revision: String?) -> ModelManifest {
            ModelManifest(requiredOsaurusVersion: nil, modelVersion: revision)
        }
        #expect(manifest("10").isNewer(than: manifest("2")))
        #expect(!manifest("2").isNewer(than: manifest("10")))
        #expect(!manifest("01").isNewer(than: manifest("1")))
        #expect(!manifest("1").isNewer(than: manifest(nil)))
        #expect(manifest(String(repeating: "9", count: 80)).isNewer(than: manifest("10")))
    }

    @Test func localAdmissionLegacyMalformedInterruptedAndWarmChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sidecar = directory.appendingPathComponent(ModelManifest.filename)
        #expect(ModelManifest.read(at: directory) == .absent)
        try ModelManifest.validateLoad(at: directory, hostVersion: "0.25.2")
        try Data(#"{"required_osaurus_version":"0.25.0","model_version":"1"}"#.utf8).write(to: sidecar)
        try ModelManifest.validateLoad(at: directory, hostVersion: "0.25.2")
        // Re-read each admission: a cached manifest must not bypass changes on disk.
        try Data(#"{"required_osaurus_version":"999.0.0","model_version":"2"}"#.utf8).write(to: sidecar)
        #expect(ModelManifest.loadFailure(at: directory, hostVersion: "0.25.2")?.reason == .requiresOsaurusUpdate)
        try Data("{".utf8).write(to: sidecar)
        #expect(ModelManifest.loadFailure(at: directory, hostVersion: "0.25.2")?.reason == .invalidManifest)
        try Data(repeating: 32, count: ModelManifest.maximumBytes + 1).write(to: sidecar)
        #expect(ModelManifest.loadFailure(at: directory, hostVersion: "0.25.2")?.reason == .invalidManifest)
        try FileManager.default.removeItem(at: sidecar)
        let pending = directory.appendingPathComponent(ModelManifest.pendingUpdateFilename)
        try Data().write(to: pending)
        #expect(ModelManifest.loadFailure(at: directory, hostVersion: "0.25.2")?.reason == .incompleteModelUpdate)
        try FileManager.default.removeItem(at: pending)
        try ModelManifest.validateLoad(at: directory, hostVersion: "0.25.2")
    }

    @Test(arguments: [200, 404, 401, 403])
    func remoteAbsenceAndFailuresRemainDistinct(status: Int) async throws {
        let revision = String(repeating: "a", count: 40)
        let service = HuggingFaceService(metadataRequest: { request in
            let url = try #require(request.url)
            if url.path.contains("/revision/main") {
                return (
                    Data("{\"sha\":\"\(revision)\"}".utf8),
                    HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
            #expect(url.path == "/org/repo/resolve/\(revision)/osaurus.json")
            return (
                Data(#"{"required_osaurus_version":"0.25.0","model_version":"10"}"#.utf8),
                HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            )
        })
        do {
            let snapshot = try await service.fetchModelManifest(repoId: "org/repo")
            #expect(status == 200 || status == 404)
            #expect(snapshot.revision == revision)
            #expect(snapshot.manifest?.modelVersion == (status == 200 ? "10" : nil))
        } catch let error as DirectDownloader.HTTPStatusError {
            #expect(status == 401 || status == 403)
            #expect(error.statusCode == status)
        }
    }

    @Test func danglingSidecarIsInvalidWhileValidSymlinkRemainsSupported() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("publisher-manifest.json")
        let sidecar = directory.appendingPathComponent(ModelManifest.filename)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
        #expect(ModelManifest.loadFailure(at: directory, hostVersion: "0.25.2")?.reason == .invalidManifest)
        #expect(try ModelManifest.removeObsoleteManifest(at: directory, advertised: false, explicitRepair: true))
        #expect(ModelManifest.read(at: directory) == .absent)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
        try Data(#"{"required_osaurus_version":"0.25.0","model_version":"1"}"#.utf8).write(to: target)
        try ModelManifest.validateLoad(at: directory, hostVersion: "0.25.2")
        #expect(ModelManifest.read(at: directory).manifest?.modelVersion == "1")
        try FileManager.default.removeItem(at: sidecar)
        #expect(ModelManifest.read(at: directory) == .absent)
    }

    @Test func remoteMalformedAndOversizedNeverBecomeAbsence() async throws {
        for body in [Data("{".utf8), Data(repeating: 32, count: ModelManifest.maximumBytes + 1)] {
            let service = HuggingFaceService(metadataRequest: { request in
                (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
            await #expect(throws: ModelManifest.Failure.self) {
                try await service.fetchModelManifest(repoId: "org/repo", revision: String(repeating: "a", count: 40))
            }
        }
    }

    @Test func resumedDownloadRetainsItsImmutableRevision() async throws {
        let revision = String(repeating: "b", count: 40)
        let service = HuggingFaceService(metadataRequest: { request in
            let url = try #require(request.url)
            // A resume must not consult a moving main branch.
            #expect(url.path == "/api/models/org/repo/tree/\(revision)")
            let body = Data(#"[{"path":"config.json","type":"file","size":5,"oid":"abc"}]"#.utf8)
            return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let files = try await service.fetchDownloadFiles(repoId: "org/repo", patterns: ["*.json"], revision: revision)
        #expect(files.count == 1)
        #expect(files.first?.revision == revision)
    }

    @Test func automaticTopUpNeverStampsRemoteRevisionOnUnverifiedWeights() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = [
            HuggingFaceService.MatchedFile(path: "osaurus.json", size: 80),
            HuggingFaceService.MatchedFile(path: "generation_config.json", size: 100),
        ]
        #expect(
            ModelDownloadService.filesToFetch(remote: files, under: directory, intent: .automatic).map(\.path)
                == ["generation_config.json"]
        )
        #expect(ModelDownloadService.filesToFetch(remote: files, under: directory, intent: .explicitRepair).count == 2)
    }

    @Test(arguments: [false, true], [false, true])
    func obsoleteManifestRemovalRequiresExplicitRepairAndRemoteAbsence(explicitRepair: Bool, advertised: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sidecar = directory.appendingPathComponent(ModelManifest.filename)
        try Data("broken manifest".utf8).write(to: sidecar)
        try Data("user note".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        let removed = try ModelManifest.removeObsoleteManifest(
            at: directory,
            advertised: advertised,
            explicitRepair: explicitRepair
        )
        #expect(removed == (explicitRepair && !advertised))
        #expect(FileManager.default.fileExists(atPath: sidecar.path) != removed)
        #expect(try String(contentsOf: directory.appendingPathComponent("notes.txt"), encoding: .utf8) == "user note")
    }

    @Test func versionRefusalsUseClientErrorEnvelopes() {
        let failure = ModelManifest.Failure(reason: .requiresOsaurusUpdate, message: "Update Osaurus.")
        #expect(HTTPHandler.localRuntimeHTTPStatus(for: failure).code == 400)
        #expect(HTTPHandler.openAIErrorType(for: failure) == "invalid_request_error")
        #expect(HTTPHandler.anthropicErrorType(for: failure) == "invalid_request_error")
        #expect(HTTPHandler.openResponsesErrorCode(for: failure) == "invalid_request_error")
        #expect(HTTPHandler.ollamaErrorType(for: failure) == "invalid_request_error")
    }
}
