//
//  DistributedHostDiagnosticsTests.swift
//  OsaurusCoreTests
//

import Foundation
import Testing

@testable import OsaurusCore

struct ThunderboltTopologyTests {
    private func parse(_ text: String) throws -> [ThunderboltPort] {
        try #require(ThunderboltTopology.parse(Data(text.utf8)))
    }

    @Test func parsesRealCabledPairFromLocalSide() throws {
        let ports = try parse(DistributedFixtures.localThunderbolt)
        #expect(ports.map(\.receptacle) == [1, 2, 3], "ports sort by receptacle, not bus order")
        let cabled = try #require(ports.first { $0.receptacle == 2 })
        #expect(cabled.busName == "thunderboltusb4_bus_1")
        #expect(cabled.ownDomainUUID == DistributedFixtures.localDomain)
        #expect(cabled.hardwarePortName == "Thunderbolt 2")
        #expect(cabled.connected)
        #expect(cabled.linkGbps == 80)
        let peer = try #require(cabled.peers.first)
        #expect(cabled.peers.count == 1)
        #expect(peer.domainUUID == DistributedFixtures.peerDomain)
        #expect(peer.model == "Mac17,6")
        #expect(peer.offersIPService)
    }

    @Test func peerSideIsReciprocal() throws {
        let local = try parse(DistributedFixtures.localThunderbolt)
        let peer = try parse(DistributedFixtures.peerThunderbolt)
        let localCable = try #require(local.first { !$0.peers.isEmpty })
        let peerCable = try #require(peer.first { !$0.peers.isEmpty })
        #expect(localCable.peers.first?.domainUUID == peerCable.ownDomainUUID)
        #expect(peerCable.peers.first?.domainUUID == localCable.ownDomainUUID)
    }

    @Test func dockIsADeviceNotAPeerMac() throws {
        let ports = try parse(DistributedFixtures.localThunderbolt)
        let dock = try #require(ports.first { $0.receptacle == 3 })
        #expect(dock.peers.isEmpty)
        #expect(dock.devices == ["SB-XTM5"])
        #expect(dock.connected)
        #expect(dock.linkGbps == 80)
    }

    @Test func idlePortHasNoLinkRate() throws {
        let ports = try parse(DistributedFixtures.localThunderbolt)
        let idle = try #require(ports.first { $0.receptacle == 1 })
        #expect(!idle.connected)
        #expect(idle.speed == "Up to 120 Gb/s")
        #expect(idle.linkGbps == nil, "an 'Up to' rate is capability, not a measured link")
    }

    @Test func macBehindADockIsNotADirectCable() throws {
        let json = #"""
            {"SPThunderboltDataType":[{"_name":"bus0","domain_uuid_key":"aaaa",
              "receptacle_1_tag":{"receptacle_id_key":"1","receptacle_status_key":"receptacle_connected","current_speed_key":"40 Gb/s"},
              "_items":[{"_name":"Dock","_items":[{"_name":"Mac Studio","domain_uuid_key":"bbbb"}]}]}]}
            """#
        let port = try #require(try parse(json).first)
        #expect(port.peers.isEmpty)
        #expect(port.devices == ["Dock", "Mac Studio (via Dock)"])
        #expect(port.ownDomainUUID == "AAAA", "domain UUIDs are normalised to upper case")
    }

    @Test func malformedPayloadsAreUnreadableNotEmpty() {
        #expect(ThunderboltTopology.parse(Data("not json".utf8)) == nil)
        #expect(ThunderboltTopology.parse(Data("{}".utf8)) == nil)
        #expect(ThunderboltTopology.parse(Data(#"{"SPThunderboltDataType":{}}"#.utf8)) == nil)
        #expect(ThunderboltTopology.parse(Data(#"{"SPThunderboltDataType":[]}"#.utf8)) == [])
    }

    @Test func busWithoutNameOrReceptacleIsTolerated() throws {
        let ports = try parse(#"{"SPThunderboltDataType":[{"domain_uuid_key":"x"},{"_name":"bus9"}]}"#)
        #expect(ports.count == 1)
        #expect(ports[0].receptacle == nil)
        #expect(ports[0].hardwarePortName == nil)
        #expect(!ports[0].connected)
    }
}

struct HostCommandParserTests {
    @Test func hardwarePortsMapThunderboltReceptaclesToInterfaces() {
        let map = HardwarePortMap.parse(DistributedFixtures.hardwarePorts)
        #expect(map["Thunderbolt 2"] == "en6")
        #expect(map["Thunderbolt Bridge"] == "bridge0")
        #expect(map["Wi-Fi"] == "en0")
        #expect(map.count == 6)
        #expect(HardwarePortMap.parse("Hardware Port: Orphan\n\nHardware Port: X\nDevice: en9")["Orphan"] == nil)
    }

    @Test func rdmaStatusIsExact() {
        #expect(RDMAState.parse(rdmaCtlStatus: "enabled\n") == .enabled)
        #expect(RDMAState.parse(rdmaCtlStatus: "  Disabled ") == .disabled)
        #expect(RDMAState.parse(rdmaCtlStatus: "partially enabled") == .unknown("partially enabled"))
        #expect(RDMAState.parse(rdmaCtlStatus: "") == .unknown("empty rdma_ctl status"))
        #expect(RDMAState.parse(rdmaCtlStatus: nil) == .unknown("rdma_ctl did not answer"))
    }

    @Test func ibvDevicesParsesRealListAndEmptyHeader() {
        let devices = RDMADeviceList.parse(ibvDevices: DistributedFixtures.peerIBVDevices)
        #expect(devices.map(\.name) == ["rdma_en1", "rdma_en6", "rdma_en2"])
        #expect(devices.map(\.interface) == ["en1", "en6", "en2"])
        #expect(RDMADeviceList.parse(ibvDevices: DistributedFixtures.emptyIBVDevices).isEmpty)
        #expect(RDMADeviceList.parse(ibvDevices: "").isEmpty)
    }

    @Test func ibvDevinfoMergesPortStateAndLinkLayer() {
        let devices = RDMADeviceList.merge(
            ibvDevinfo: DistributedFixtures.peerIBVDevinfo,
            into: RDMADeviceList.parse(ibvDevices: DistributedFixtures.peerIBVDevices)
        )
        #expect(devices.count == 3)
        #expect(devices.allSatisfy { $0.portState == "PORT_DOWN" && $0.linkLayer == "Thunderbolt" })
        #expect(devices.allSatisfy { !$0.isActive }, "PORT_DOWN while the other side has RDMA disabled")
        let active = RDMADeviceList.merge(ibvDevinfo: "hca_id: rdma_en9\n\t\tstate: PORT_ACTIVE (4)", into: devices)
        #expect(active.count == 4)
        #expect(active.last?.isActive == true)
        #expect(RDMADeviceList.merge(ibvDevinfo: "No IB devices found", into: devices) == devices)
    }

    @Test func linkSummaryJoinsReceptacleInterfaceRDMAAndAddresses() throws {
        let ports = try #require(ThunderboltTopology.parse(Data(DistributedFixtures.peerThunderbolt.utf8)))
        let devices = RDMADeviceList.merge(
            ibvDevinfo: DistributedFixtures.peerIBVDevinfo,
            into: RDMADeviceList.parse(ibvDevices: DistributedFixtures.peerIBVDevices)
        )
        let links = ThunderboltLinkSummary.build(
            ports: ports,
            hardwarePorts: HardwarePortMap.parse(DistributedFixtures.hardwarePorts),
            rdmaDevices: devices,
            addresses: ["en6": ["fe80::1%en6"]]
        )
        let cabled = try #require(links.first { $0.cabledMac != nil })
        #expect(cabled.interface == "en6")
        #expect(cabled.rdmaDevice?.name == "rdma_en6")
        #expect(cabled.rdmaDevice?.portState == "PORT_DOWN")
        #expect(cabled.addresses == ["fe80::1%en6"])
        #expect(cabled.cabledMac?.domainUUID == DistributedFixtures.localDomain)
        let unmapped = ThunderboltLinkSummary.build(
            ports: ports,
            hardwarePorts: [:],
            rdmaDevices: devices,
            addresses: [:]
        )
        #expect(unmapped.allSatisfy { $0.interface == nil && $0.rdmaDevice == nil })
    }

    @Test func interfaceAddressesIncludeLoopback() {
        let addresses = InterfaceAddresses.read()
        #expect(addresses["lo0"]?.contains("127.0.0.1") == true)
    }
}

struct DiagnosticCommandTests {
    private func leftovers() -> Set<String> {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("osaurus-distributed-") })
    }

    @Test func missingExecutableIsReportedAsMissing() {
        let result = DiagnosticCommand.run("/usr/bin/definitely-not-a-real-tool", [])
        #expect(result.missing)
        #expect(result.output == nil)
    }

    @Test func capturesOutputAndRemovesTemporaryFile() {
        let before = leftovers()
        #expect(DiagnosticCommand.text("/bin/echo", ["hello"]) == "hello\n")
        #expect(leftovers() == before, "the private output file must be removed")
    }

    @Test func nonZeroExitHasNoText() {
        #expect(DiagnosticCommand.text("/usr/bin/false", []) == nil)
        #expect(DiagnosticCommand.run("/usr/bin/false", []).exitStatus == 1)
    }

    @Test func deadlineStopsOnlyTheOwnedProcess() {
        let before = leftovers()
        let started = Date()
        let result = DiagnosticCommand.run("/bin/sleep", ["30"], timeout: 0.3)
        #expect(result.timedOut)
        #expect(result.output == nil)
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(leftovers() == before)
    }

    @Test func largeOutputDoesNotDeadlockAndIsBounded() {
        // 2 MiB would fill any pipe; a file cannot. Over the cap reads as nil.
        let result = DiagnosticCommand.run("/bin/dd", ["if=/dev/zero", "bs=1048576", "count=2"], timeout: 10)
        #expect(!result.timedOut)
        #expect(result.exitStatus == 0)
        #expect(result.output == nil)
    }
}
