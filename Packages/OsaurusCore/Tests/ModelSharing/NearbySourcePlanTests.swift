import Foundation
import OsaurusSync
import Testing

@testable import OsaurusCore

@Suite("Nearby source plan")
struct NearbySourcePlanTests {
    private static let weightsDigest = String(repeating: "ab", count: 32)

    private func offer(
        host: String,
        kind: String = "language",
        id: String = "language:mlx-community/Raptor-4bit",
        repoId: String? = "mlx-community/Raptor-4bit",
        files: [NearbyModelFile]
    ) -> NearbyOffer {
        NearbyOffer(
            hostId: host,
            hostName: "Mac \(host)",
            model: NearbyModel(
                id: id,
                kind: kind,
                format: kind == "image" ? "mflux" : "mlx",
                name: "Raptor",
                repoId: repoId,
                revision: nil,
                files: files
            )
        )
    }

    private func weights(_ index: Int, sha256: String = weightsDigest) -> NearbyModelFile {
        NearbyModelFile(path: "model-\(index).safetensors", size: 100, sha256: sha256)
    }

    private func hubFile(_ index: Int, digest: ModelFileDigest? = .sha256(weightsDigest), size: Int64 = 100)
        -> HuggingFaceService.MatchedFile
    {
        HuggingFaceService.MatchedFile(path: "model-\(index).safetensors", size: size, digest: digest)
    }

    @Test func picksAHostWhoseFileMatchesTheHubDigest() {
        let plan = ModelDownloadService.nearbyPlan(
            files: [hubFile(1)],
            offers: [offer(host: "a", files: [weights(1)])],
            preferredHostId: nil
        )
        #expect(plan["model-1.safetensors"]?.hostId == "a")
        #expect(plan["model-1.safetensors"]?.itemId == "language:mlx-community/Raptor-4bit")
    }

    @Test func skipsFilesTheHubDisagreesWithOrCannotVouchFor() {
        let offers = [offer(host: "a", files: [weights(1, sha256: String(repeating: "cd", count: 32)), weights(2), weights(3)])]
        let plan = ModelDownloadService.nearbyPlan(
            files: [hubFile(1), hubFile(2, digest: nil), hubFile(3, size: 101)],
            offers: offers,
            preferredHostId: nil
        )
        #expect(plan.isEmpty)
    }

    @Test func digestComparisonIgnoresCase() {
        let plan = ModelDownloadService.nearbyPlan(
            files: [hubFile(1, digest: .sha256(Self.weightsDigest.uppercased()))],
            offers: [offer(host: "a", files: [weights(1)])],
            preferredHostId: nil
        )
        #expect(plan.count == 1)
    }

    /// Small files carry a git blob SHA-1 the host doesn't publish; path and
    /// size pick the host and the downloaded bytes are checked afterwards.
    @Test func gitBlobFilesMatchOnPathAndSize() {
        let plan = ModelDownloadService.nearbyPlan(
            files: [hubFile(1, digest: .gitBlobSHA1(String(repeating: "1", count: 40)))],
            offers: [offer(host: "a", files: [weights(1, sha256: "unrelated")])],
            preferredHostId: nil
        )
        #expect(plan["model-1.safetensors"]?.hostId == "a")
    }

    @Test func preferredHostWinsWhenItHasTheFile() {
        let files = (1 ... 4).map { weights($0) }
        let plan = ModelDownloadService.nearbyPlan(
            files: (1 ... 4).map { hubFile($0) },
            offers: [offer(host: "a", files: files), offer(host: "b", files: files)],
            preferredHostId: "b"
        )
        #expect(Set(plan.values.map(\.hostId)) == ["b"])
    }

    @Test func spreadsFilesAcrossHostsWithoutAPreference() {
        let files = (1 ... 4).map { weights($0) }
        let plan = ModelDownloadService.nearbyPlan(
            files: (1 ... 4).map { hubFile($0) },
            offers: [offer(host: "a", files: files), offer(host: "b", files: files)],
            preferredHostId: nil
        )
        let perHost = Dictionary(grouping: plan.values, by: \.hostId).mapValues(\.count)
        #expect(perHost == ["a": 2, "b": 2])
    }

    @Test func offerMatchesItsCatalogRowByIdOrRepo() {
        let raptor = offer(host: "a", files: [weights(1)])
        #expect(raptor.localId == "mlx-community/Raptor-4bit")
        #expect(raptor.kind == .language)
        #expect(raptor.totalBytes == 100)
        #expect(raptor.matches(kind: .language, localId: "MLX-Community/raptor-4bit"))
        #expect(raptor.matches(kind: .language, localId: "raptor-local", repoId: "mlx-community/Raptor-4bit"))
        #expect(!raptor.matches(kind: .embedding, localId: "mlx-community/Raptor-4bit"))
        #expect(!raptor.matches(kind: .language, localId: "other/model"))

        let image = offer(host: "a", kind: "image", id: "image:flux-schnell", repoId: nil, files: [])
        #expect(image.localId == "flux-schnell")
        #expect(image.matches(kind: .image, localId: "flux-schnell"))
    }

    @Test func shareErrorsBecomeUserFacingReasons() {
        #expect(NearbyTransferError(.Busy(detail: ""), hostName: "Studio") == .hostBusy(hostName: "Studio"))
        #expect(NearbyTransferError(.NotRunning(detail: ""), hostName: "Studio") == .notRunning)
        #expect(NearbyTransferError(.InvalidInput(detail: "../x"), hostName: "Studio") == .invalidPath("../x"))
        for error in [ModelShareError.NotFound(detail: ""), .Unreachable(detail: ""), .Io(detail: "")] {
            #expect(NearbyTransferError(error, hostName: "Studio") == .hostUnavailable(hostName: "Studio"))
        }
        #expect(
            NearbyTransferError.hostUnavailable(hostName: "Studio").errorDescription
                == "Studio is no longer reachable. Try again when it's back on this network."
        )
    }

    @Test func nearbyChipShowsOnlyWhenSomeRowIsOnANearbyMac() {
        var installed = row("a", status: .installed)
        installed.nearbyHosts = ["Studio"]
        let available = row("b", status: .available)
        #expect(LocalModelCatalogScope.chips(for: [installed, available]) == [.onThisMac, .available, .all])

        var nearby = row("c", status: .available)
        nearby.nearbyHosts = ["Studio"]
        #expect(LocalModelCatalogScope.chips(for: [installed, nearby]) == [.onThisMac, .available, .nearby, .all])
        #expect(LocalModelCatalogScope.nearby.includes(nearby))
        #expect(!LocalModelCatalogScope.nearby.includes(installed))
        #expect(!LocalModelCatalogScope.nearby.includes(available))
    }

    private func row(_ id: String, status: LocalModelCatalogItem.Status) -> LocalModelCatalogItem {
        LocalModelCatalogItem(id: id, name: id, subtitle: "", icon: "cpu", status: status)
    }
}
