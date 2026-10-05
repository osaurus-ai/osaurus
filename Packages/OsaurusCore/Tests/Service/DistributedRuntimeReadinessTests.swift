// Copyright © 2026 osaurus.

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Distributed runtime readiness")
struct DistributedRuntimeReadinessTests {
    @Test("Thunderbolt loopback and direct addresses are accepted")
    func thunderboltAddressesAreAccepted() {
        let loopback = DistributedTensorEndpoint("10.20.0.1:29500")
        let direct = DistributedTensorEndpoint("10.10.6.2")

        #expect(loopback.addressClass == .thunderboltLoopback)
        #expect(loopback.isAllowedForTensorDataPlane)
        #expect(direct.addressClass == .thunderboltDirect)
        #expect(direct.isAllowedForTensorDataPlane)
    }

    @Test("Tailscale addresses are control-plane only")
    func tailscaleAddressesAreRejected() {
        let report = DistributedRuntimeReadiness.evaluate(
            dataPlaneAddresses: ["10.20.0.1:29500", "100.93.216.67:29500"],
            worldSize: 4,
            librdmaLoadable: true,
            jacclAvailable: true,
            ibvDevicesConfigured: true
        )

        #expect(!report.isRunnable)
        #expect(report.readinessState == .blocked)
        #expect(report.endpoints.map(\.addressClass).contains(.tailscaleControl))
        #expect(report.findings.contains { $0.code == "tailscale_data_plane_forbidden" && $0.level == .error })
    }

    @Test("Size one fallback is not tensor-parallel proof")
    func sizeOneFallbackIsRejected() {
        let report = DistributedRuntimeReadiness.evaluate(
            dataPlaneAddresses: ["10.20.0.1:29500"],
            worldSize: 1,
            librdmaLoadable: true,
            jacclAvailable: true,
            ibvDevicesConfigured: true
        )

        #expect(!report.isRunnable)
        #expect(report.readinessState == .blocked)
        #expect(report.findings.contains { $0.code == "single_rank_not_tp" })
    }

    @Test("JACCL and IBV gates stay separate from librdma")
    func jacclAndIBVGatesStaySeparate() {
        let report = DistributedRuntimeReadiness.evaluate(
            dataPlaneAddresses: ["10.20.0.1:29500", "10.20.0.2:29500"],
            worldSize: 4,
            librdmaLoadable: true,
            jacclAvailable: false,
            ibvDevicesConfigured: false
        )

        #expect(!report.isRunnable)
        #expect(report.readinessState == .blocked)
        #expect(!report.findings.contains { $0.code == "librdma_unavailable" })
        #expect(report.findings.contains { $0.code == "jaccl_unavailable" })
        #expect(report.findings.contains { $0.code == "ibv_devices_missing" })
    }

    @Test("Unknown private addresses are warnings, not proof")
    func unknownPrivateAddressesAreWarnings() {
        let report = DistributedRuntimeReadiness.evaluate(
            dataPlaneAddresses: ["192.168.1.20"],
            worldSize: 4,
            librdmaLoadable: true,
            jacclAvailable: true,
            ibvDevicesConfigured: true
        )

        #expect(!report.isRunnable)
        #expect(report.readinessState == .partial)
        #expect(report.endpoints.first?.addressClass == .privateOther)
        #expect(report.findings.contains { $0.code == "unproven_data_plane_address" && $0.level == .warning })
    }

    @Test("Clean Thunderbolt gates are ready")
    func cleanThunderboltGatesAreReady() {
        let report = DistributedRuntimeReadiness.evaluate(
            dataPlaneAddresses: ["10.20.0.1:29500", "10.20.0.2:29500"],
            worldSize: 2,
            librdmaLoadable: true,
            jacclAvailable: true,
            ibvDevicesConfigured: true
        )

        #expect(report.isRunnable)
        #expect(report.readinessState == .ready)
        #expect(report.findings.allSatisfy { $0.level == .info })
    }

    @Test("Discovery record is stable JSON for the future node panel")
    func discoveryRecordEncodesStableJSON() throws {
        let report = DistributedRuntimeReadiness.evaluate(
            dataPlaneAddresses: ["10.20.0.1:29500", "10.20.0.2:29500"],
            worldSize: 2,
            librdmaLoadable: true,
            jacclAvailable: false,
            ibvDevicesConfigured: false
        )
        let record = DistributedNodeDiscoveryRecord(
            nodeID: "node-a",
            deviceName: "m5-max-a",
            osaurusVersion: "0.0-test",
            osaurusCommit: "abcdef0",
            vmlxPin: "7e69522f85f5a384d69f1673ab45c98d60d28375",
            roles: [.coordinator, .rankWorker],
            controlEndpoints: ["m5-max-a.local:1337"],
            dataPlaneCandidates: ["10.20.0.1:29500", "10.20.0.2:29500"],
            readiness: report
        )

        let data = try JSONEncoder().encode(record)
        let json = try #require(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(DistributedNodeDiscoveryRecord.self, from: data)

        #expect(json.contains("\"node_id\""))
        #expect(json.contains("\"device_name\""))
        #expect(json.contains("\"vmlx_pin\""))
        #expect(json.contains("\"distributed_capability_version\""))
        #expect(json.contains("\"control_endpoints\""))
        #expect(json.contains("\"data_plane_candidates\""))
        #expect(json.contains("\"readiness_state\":\"blocked\""))
        #expect(json.contains("\"is_runnable\":false"))
        #expect(json.contains("\"address_class\":\"thunderboltLoopback\""))
        #expect(decoded.nodeID == "node-a")
        #expect(decoded.vmlxPin == "7e69522f85f5a384d69f1673ab45c98d60d28375")
        #expect(decoded.roles == [.coordinator, .rankWorker])
        #expect(decoded.dataPlaneCandidates.map(\.addressClass).allSatisfy { $0 == .thunderboltLoopback })
        #expect(decoded.readiness.readinessState == .blocked)
        #expect(decoded.readiness.findings.contains { $0.code == "jaccl_unavailable" })
    }

    @Test("IBV matrix accepts null and empty self slots")
    func ibvMatrixAcceptsNullAndEmptySelfSlots() throws {
        let nullSelf = try DistributedIBVDeviceMatrix(jsonData: Data("""
        [
          [null, "rdma_en5"],
          ["rdma_en5", null]
        ]
        """.utf8))
        let emptySelf = DistributedIBVDeviceMatrix(rows: [
            ["", "mlx0"],
            ["mlx0", ""],
        ])

        #expect(nullSelf.isValid(worldSize: 2))
        #expect(emptySelf.isValid(worldSize: 2))
        #expect(nullSelf.findings(worldSize: 2).contains { $0.code == "ibv_matrix_valid" })
        #expect(emptySelf.findings(worldSize: 2).contains { $0.code == "ibv_matrix_valid" })
    }

    @Test("IBV matrix rejects malformed shape and missing peer devices")
    func ibvMatrixRejectsMalformedShapeAndMissingPeerDevices() {
        let wrongWorldSize = DistributedIBVDeviceMatrix(rows: [
            [nil, "rdma_en5"],
            ["rdma_en5", nil],
        ])
        let notSquare = DistributedIBVDeviceMatrix(rows: [
            [nil, "rdma_en5"],
            ["rdma_en5"],
        ])
        let selfDevice = DistributedIBVDeviceMatrix(rows: [
            ["rdma_en5", "rdma_en5"],
            ["rdma_en5", nil],
        ])
        let missingPeer = DistributedIBVDeviceMatrix(rows: [
            [nil, ""],
            ["rdma_en5", nil],
        ])

        #expect(wrongWorldSize.findings(worldSize: 4).contains { $0.code == "ibv_matrix_world_size_mismatch" })
        #expect(notSquare.findings(worldSize: 2).contains { $0.code == "ibv_matrix_not_square" })
        #expect(selfDevice.findings(worldSize: 2).contains { $0.code == "ibv_matrix_self_slot_not_empty" })
        #expect(missingPeer.findings(worldSize: 2).contains { $0.code == "ibv_matrix_peer_device_missing" })
    }

    @Test("Readiness report includes IBV matrix findings")
    func readinessReportIncludesIBVMatrixFindings() {
        let report = DistributedRuntimeReadiness.evaluate(
            dataPlaneAddresses: ["10.20.0.1:29500", "10.20.0.2:29500"],
            worldSize: 2,
            librdmaLoadable: true,
            jacclAvailable: true,
            ibvDevicesConfigured: true,
            ibvDeviceMatrix: .init(rows: [
                [nil, ""],
                ["rdma_en5", nil],
            ])
        )

        #expect(!report.isRunnable)
        #expect(report.readinessState == .blocked)
        #expect(report.findings.contains { $0.code == "ibv_matrix_peer_device_missing" })
    }
}
