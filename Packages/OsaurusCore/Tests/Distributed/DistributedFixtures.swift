//
//  DistributedFixtures.swift
//  OsaurusCoreTests
//
//  Captured 2026-09-26 from two M5 Max MacBook Pros joined by one Thunderbolt
//  cable (macOS 27.0). Hardware identifiers (domain UUIDs, MAC addresses, RDMA
//  GUIDs, switch UIDs) were replaced with synthetic values; structure and the
//  relationships between them are unchanged. "local" has RDMA disabled; "peer" has RDMA enabled.
//  Their bus-1 domain UUIDs are reciprocal: each lists the other as the host
//  on its receptacle 2.
//

enum DistributedFixtures {
    static let localDomain = "00000004-0000-4000-8000-000000000004"
    static let peerDomain = "00000003-0000-4000-8000-000000000003"

    static let localThunderbolt = #"""
        {
         "SPThunderboltDataType": [
          {
           "_items": [
            {
             "_name": "SB-XTM5",
             "device_id_key": "0x501",
             "device_name_key": "SB-XTM5",
             "device_revision_key": "0x1",
             "mode_key": "usb_four_v2",
             "receptacle_2_tag": {
              "current_speed_key": "Up to 120 Gb/s",
              "link_status_key": "0x7",
              "micro_version_key": "1.9.0",
              "receptacle_status_key": "receptacle_no_devices_connected"
             },
             "receptacle_3_tag": {
              "current_speed_key": "Up to 120 Gb/s",
              "link_status_key": "0x7",
              "micro_version_key": "1.9.0",
              "receptacle_status_key": "receptacle_no_devices_connected"
             },
             "receptacle_4_tag": {
              "current_speed_key": "Up to 120 Gb/s",
              "link_status_key": "0x7",
              "micro_version_key": "1.9.0",
              "receptacle_status_key": "receptacle_no_devices_connected"
             },
             "receptacle_upstream_ambiguous_tag": {
              "current_speed_key": "80 Gb/s",
              "link_status_key": "0x2",
              "micro_version_key": "1.9.0",
              "receptacle_status_key": "receptacle_connected"
             },
             "route_string_key": "1",
             "switch_uid_key": "0x0000000000000008",
             "switch_version_key": "62.1",
             "vendor_id_key": "0x2EB9",
             "vendor_name_key": "Sabrent"
            }
           ],
           "_name": "thunderboltusb4_bus_2",
           "device_name_key": "MacBook Pro",
           "domain_uuid_key": "00000009-0000-4000-8000-000000000009",
           "receptacle_1_tag": {
            "current_speed_key": "80 Gb/s",
            "link_status_key": "0x4",
            "micro_version_key": "0.0.0",
            "receptacle_id_key": "3",
            "receptacle_status_key": "receptacle_connected"
           },
           "route_string_key": "0",
           "switch_uid_key": "0x0000000000000004",
           "vendor_name_key": "Apple Inc."
          },
          {
           "_items": [
            {
             "_name": "MacBook Pro",
             "device_id_key": "0xA",
             "device_name_key": "Mac17,6",
             "domain_uuid_key": "00000003-0000-4000-8000-000000000003",
             "services_title": [
              {
               "_name": "service_ip",
               "protocol_id_key": 1,
               "protocol_revision_key": 1,
               "protocol_version_key": 1,
               "service_uuid_key": "00000007-0000-4000-8000-000000000007"
              },
              {
               "_name": "unknown_xd_service",
               "protocol_id_key": 64087,
               "protocol_revision_key": 0,
               "protocol_version_key": 1,
               "service_key_key": "\u02c7\u02c7\u02c7\u02c7\u02c7\u02c7AD",
               "service_uuid_key": "00000001-0000-4000-8000-000000000001"
              }
             ],
             "vendor_id_key": "0x0A27",
             "vendor_name_key": "Apple Inc."
            }
           ],
           "_name": "thunderboltusb4_bus_1",
           "device_name_key": "MacBook Pro",
           "domain_uuid_key": "00000004-0000-4000-8000-000000000004",
           "receptacle_1_tag": {
            "current_speed_key": "80 Gb/s",
            "link_status_key": "0x2",
            "micro_version_key": "0.0.0",
            "receptacle_id_key": "2",
            "receptacle_status_key": "receptacle_connected"
           },
           "route_string_key": "0",
           "switch_uid_key": "0x0000000000000003",
           "vendor_name_key": "Apple Inc."
          },
          {
           "_name": "thunderboltusb4_bus_0",
           "device_name_key": "MacBook Pro",
           "domain_uuid_key": "00000008-0000-4000-8000-000000000008",
           "receptacle_1_tag": {
            "current_speed_key": "Up to 120 Gb/s",
            "link_status_key": "0x100",
            "receptacle_id_key": "1",
            "receptacle_status_key": "receptacle_no_devices_connected"
           },
           "route_string_key": "0",
           "switch_uid_key": "0x0000000000000002",
           "vendor_name_key": "Apple Inc."
          }
         ]
        }
        """#

    static let peerThunderbolt = #"""
        {
         "SPThunderboltDataType": [
          {
           "_items": [
            {
             "_name": "TBU405Pro",
             "device_id_key": "0x1",
             "device_name_key": "TBU405Pro",
             "device_revision_key": "0x1",
             "mode_key": "thunderbolt_three",
             "receptacle_upstream_ambiguous_tag": {
              "current_speed_key": "40 Gb/s",
              "lc_version_key": "1.45.0",
              "link_status_key": "0x2",
              "receptacle_status_key": "receptacle_connected"
             },
             "route_string_key": "1",
             "switch_uid_key": "0x0000000000000001",
             "switch_version_key": "67.1",
             "vendor_id_key": "0x0025",
             "vendor_name_key": "ACASIS"
            }
           ],
           "_name": "thunderboltusb4_bus_2",
           "device_name_key": "MacBook Pro",
           "domain_uuid_key": "00000002-0000-4000-8000-000000000002",
           "receptacle_1_tag": {
            "current_speed_key": "40 Gb/s",
            "link_status_key": "0x2",
            "micro_version_key": "0.0.0",
            "receptacle_id_key": "3",
            "receptacle_status_key": "receptacle_connected"
           },
           "route_string_key": "0",
           "switch_uid_key": "0x0000000000000007",
           "vendor_name_key": "Apple Inc."
          },
          {
           "_items": [
            {
             "_name": "MacBook Pro",
             "device_id_key": "0xA",
             "device_name_key": "Mac17,6",
             "domain_uuid_key": "00000004-0000-4000-8000-000000000004",
             "services_title": [
              {
               "_name": "service_ip",
               "protocol_id_key": 1,
               "protocol_revision_key": 1,
               "protocol_version_key": 1,
               "service_uuid_key": "00000006-0000-4000-8000-000000000006"
              }
             ],
             "vendor_id_key": "0x0A27",
             "vendor_name_key": "Apple Inc."
            }
           ],
           "_name": "thunderboltusb4_bus_1",
           "device_name_key": "MacBook Pro",
           "domain_uuid_key": "00000003-0000-4000-8000-000000000003",
           "receptacle_1_tag": {
            "current_speed_key": "80 Gb/s",
            "link_status_key": "0x2",
            "micro_version_key": "0.0.0",
            "receptacle_id_key": "2",
            "receptacle_status_key": "receptacle_connected"
           },
           "route_string_key": "0",
           "switch_uid_key": "0x0000000000000006",
           "vendor_name_key": "Apple Inc."
          },
          {
           "_name": "thunderboltusb4_bus_0",
           "device_name_key": "MacBook Pro",
           "domain_uuid_key": "00000005-0000-4000-8000-000000000005",
           "receptacle_1_tag": {
            "current_speed_key": "Up to 120 Gb/s",
            "link_status_key": "0x100",
            "receptacle_id_key": "1",
            "receptacle_status_key": "receptacle_no_devices_connected"
           },
           "route_string_key": "0",
           "switch_uid_key": "0x0000000000000005",
           "vendor_name_key": "Apple Inc."
          }
         ]
        }
        """#

    static let peerIBVDevices = #"""
            device          	   node GUID
            ------          	----------------
            rdma_en1        	0000000000000001
            rdma_en6        	0000000000000002
            rdma_en2        	0000000000000003
        """#

    /// `ibv_devices` on a Mac with RDMA disabled: header only.
    static let emptyIBVDevices = #"""
            device          	   node GUID
            ------          	----------------
        """#

    static let peerIBVDevinfo = #"""
        hca_id:	rdma_en1
        	transport:			Thunderbolt (100)
        	node_guid:			0000:0000:0000:0002
        	sys_image_guid:			0000:0000:0000:0001
        	vendor_id:			0x0000
        	vendor_part_id:			0
        	hw_ver:				0x0
        	phys_port_cnt:			1
        		port:	1
        			state:			PORT_DOWN (1)
        			max_mtu:		4096 (5)
        			active_mtu:		4096 (5)
        			sm_lid:			1
        			port_lid:		1
        			port_lmc:		0x00
        			link_layer:		Thunderbolt

        hca_id:	rdma_en6
        	transport:			Thunderbolt (100)
        	node_guid:			0000:0000:0000:0003
        	sys_image_guid:			0000:0000:0000:0001
        	vendor_id:			0x0000
        	vendor_part_id:			0
        	hw_ver:				0x0
        	phys_port_cnt:			1
        		port:	1
        			state:			PORT_DOWN (1)
        			max_mtu:		4096 (5)
        			active_mtu:		4096 (5)
        			sm_lid:			2
        			port_lid:		2
        			port_lmc:		0x00
        			link_layer:		Thunderbolt

        hca_id:	rdma_en2
        	transport:			Thunderbolt (100)
        	node_guid:			0000:0000:0000:0004
        	sys_image_guid:			0000:0000:0000:0001
        	vendor_id:			0x0000
        	vendor_part_id:			0
        	hw_ver:				0x0
        	phys_port_cnt:			1
        		port:	1
        			state:			PORT_DOWN (1)
        			max_mtu:		4096 (5)
        			active_mtu:		4096 (5)
        			sm_lid:			3
        			port_lid:		3
        			port_lmc:		0x00
        			link_layer:		Thunderbolt
        """#

    static let hardwarePorts = #"""
        Hardware Port: Ethernet Adapter (en3)
        Device: en3
        Ethernet Address: 02:00:00:00:00:04

        Hardware Port: Thunderbolt Bridge
        Device: bridge0
        Ethernet Address: 02:00:00:00:00:01

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: 02:00:00:00:00:05

        Hardware Port: Thunderbolt 1
        Device: en1
        Ethernet Address: 02:00:00:00:00:01

        Hardware Port: Thunderbolt 2
        Device: en6
        Ethernet Address: 02:00:00:00:00:02

        Hardware Port: Thunderbolt 3
        Device: en2
        Ethernet Address: 02:00:00:00:00:03

        VLAN Configurations
        ===================
        """#

    /// `diskutil info -plist /` fields (internal startup SSD).
    static var internalDisk: [String: Any] {
        [
            "VolumeName": "Macintosh HD", "DeviceIdentifier": "disk3s1s1",
            "APFSPhysicalStores": [["APFSPhysicalStore": "disk0s2"]], "MediaName": "",
            "BusProtocol": "Apple Fabric", "Internal": true, "SolidState": true,
            "FilesystemName": "APFS", "FilesystemType": "apfs",
        ]
    }

    /// `diskutil info -plist /Volumes/ModelSSD` fields (Thunderbolt NVMe enclosure).
    static var externalDisk: [String: Any] {
        [
            "VolumeName": "ModelSSD", "DeviceIdentifier": "disk7s1",
            "APFSPhysicalStores": [["APFSPhysicalStore": "disk6s2"]], "MediaName": "",
            "BusProtocol": "PCI-Express", "Internal": false, "SolidState": true,
            "FilesystemName": "APFS", "FilesystemType": "apfs",
        ]
    }
}
