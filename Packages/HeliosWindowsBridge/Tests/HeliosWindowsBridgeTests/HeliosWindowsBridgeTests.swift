import XCTest
@testable import HeliosWindowsBridge

final class HeliosWindowsBridgeTests: XCTestCase {
    func testPlaceholderFactoryProvidesStableBridgeSurface() {
        let services = PlatformServices.placeholder

        XCTAssertEqual(services.server.currentStatus(), "Unknown")
        XCTAssertEqual(services.server.localServerURL(), "http://127.0.0.1:1337")
        XCTAssertNil(
            services.filePicker.pickFile(
                FilePickerRequest(title: "Inspect endpoint spec", allowedExtensions: ["json"])
            )
        )
    }

    func testWinRTProjectionOrderMatchesIncrementalServicePlan() {
        XCTAssertEqual(
            HeliosWindowsBridgePlan.projectionOrder.map(\.serviceInterface),
            ["ClipboardService", "ExternalLinkService", "FilePickerService"]
        )
    }
}
