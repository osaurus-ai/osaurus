//
//  CloudMediaCatalogRouterGateTests.swift
//  osaurusTests
//
//  Pins that the Cloud media catalog honors the Osaurus Router master
//  switch: no `/v1/media/models` request while the Router is off, cached
//  Cloud models are cleared when it turns off, and a response that lands
//  after the switch flips off is discarded.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Cloud media catalog Router gate", .serialized)
struct CloudMediaCatalogRouterGateTests {

    private static let catalogJSON = #"""
        {"version":"1","models":[
          {"id":"cloud-image","display_name":"Cloud Image","operation":"image","constraints":{},"offline":false}
        ]}
        """#

    private final class RouterSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled: Bool
        init(_ enabled: Bool) { self.enabled = enabled }
        var value: Bool {
            get { lock.withLock { enabled } }
            set { lock.withLock { enabled = newValue } }
        }
    }

    private struct Fixture {
        let coordinator: MediaGenerationCoordinator
        let router: RouterSwitch
        let jobsFile: URL

        func cleanup() {
            try? FileManager.default.removeItem(at: jobsFile)
            CatalogURLProtocol.handler = nil
            CatalogURLProtocol.requestedPaths = []
        }
    }

    private func makeFixture(routerEnabled: Bool) -> Fixture {
        CatalogURLProtocol.requestedPaths = []
        CatalogURLProtocol.handler = { _ in (200, Data(Self.catalogJSON.utf8)) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogURLProtocol.self]
        let client = OsaurusRouterAPIClient(
            baseURL: URL(string: "https://router.test")!,
            session: URLSession(configuration: config),
            authOverride: { request, _ in
                request.setValue("0xabc", forHTTPHeaderField: "x-wallet-address")
            }
        )
        let router = RouterSwitch(routerEnabled)
        let jobsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-media-gate-\(UUID().uuidString).json")
        let coordinator = MediaGenerationCoordinator(
            jobs: MediaJobStore(fileURL: jobsFile),
            cloud: OsaurusCloudMediaClient(router: client),
            isRouterEnabled: { router.value }
        )
        return Fixture(coordinator: coordinator, router: router, jobsFile: jobsFile)
    }

    @Test func routerOff_makesNoRequestAndExposesNoModels() async {
        let fixture = makeFixture(routerEnabled: false)
        defer { fixture.cleanup() }

        await fixture.coordinator.refreshCloudCatalog()

        #expect(CatalogURLProtocol.requestedPaths.isEmpty)
        #expect(await fixture.coordinator.cachedCloudModels().isEmpty)
    }

    @Test func routerOn_fetchesAndCachesCatalog() async {
        let fixture = makeFixture(routerEnabled: true)
        defer { fixture.cleanup() }

        await fixture.coordinator.refreshCloudCatalog()

        #expect(CatalogURLProtocol.requestedPaths == ["/v1/media/models"])
        let models = await fixture.coordinator.cachedCloudModels()
        #expect(models.map(\.target.modelID) == ["cloud-image"])
    }

    @Test func turningRouterOff_clearsCachedModelsWithoutRequest() async {
        let fixture = makeFixture(routerEnabled: true)
        defer { fixture.cleanup() }
        await fixture.coordinator.refreshCloudCatalog()
        #expect(await !fixture.coordinator.cachedCloudModels().isEmpty)

        fixture.router.value = false
        await fixture.coordinator.refreshCloudCatalog()

        #expect(CatalogURLProtocol.requestedPaths == ["/v1/media/models"])
        #expect(await fixture.coordinator.cachedCloudModels().isEmpty)
    }

    @Test func responseAfterRouterTurnsOff_isDiscarded() async {
        let fixture = makeFixture(routerEnabled: true)
        defer { fixture.cleanup() }
        let router = fixture.router
        CatalogURLProtocol.handler = { _ in
            router.value = false
            return (200, Data(Self.catalogJSON.utf8))
        }

        await fixture.coordinator.refreshCloudCatalog()

        #expect(CatalogURLProtocol.requestedPaths == ["/v1/media/models"])
        #expect(await fixture.coordinator.cachedCloudModels().isEmpty)
    }
}

private final class CatalogURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requestedPaths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestedPaths.append(request.url?.path ?? "")
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
