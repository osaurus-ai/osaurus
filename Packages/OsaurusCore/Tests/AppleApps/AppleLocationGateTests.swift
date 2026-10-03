//
//  AppleLocationGateTests.swift
//  OsaurusCoreTests — AppleApps
//
//  The Location gate must WAIT for the user's answer to the system dialog
//  instead of sampling the status right away. Under tests there is no TCC
//  UI, so the awaited API resolves immediately to `.denied` without touching
//  CoreLocation — that is the contract pinned here, plus the status helper.
//

import CoreLocation
import Foundation
import Testing

@testable import OsaurusCore

@Suite("Apple tools: Location gate")
@MainActor
struct AppleLocationGateTests {
    @Test("isLocationAuthorized accepts both macOS spellings of an always-grant")
    func authorizedStatuses() {
        #expect(SystemPermissionService.isLocationAuthorized(.authorizedAlways))
        #expect(SystemPermissionService.isLocationAuthorized(.authorized))
        #expect(!SystemPermissionService.isLocationAuthorized(.notDetermined))
        #expect(!SystemPermissionService.isLocationAuthorized(.denied))
        #expect(!SystemPermissionService.isLocationAuthorized(.restricted))
    }

    @Test("the awaited request resolves without a dialog under tests and the dialog timeout is generous")
    func awaitedRequestUnderTests() async {
        let status = await SystemPermissionService.shared.requestLocationAuthorizationAndWait(timeout: 1)
        #expect(status == .denied)
        #expect(SystemPermissionService.shared.locationAuthorizationStatus == .denied)
        // A user reading the dialog must not be reported as "denied" after a
        // few seconds — the wait spans minutes.
        #expect(SystemPermissionService.locationDialogTimeout >= 60)
    }

    @Test("location_current's description tells the model the call waits on the dialog")
    func toolDescription() {
        let tool = MapsToolFactory.makeTools().first { $0.name == "location_current" }
        #expect(tool?.description.contains("waits") == true)
    }
}
