# RDMA/TB5 Discovery JSON Contract

Updated: 2026-06-10

This is the first stable JSON shape for RDMA/TB5 node discovery and readiness
diagnostics. It is source-backed by `DistributedNodeDiscoveryRecord` and
`DistributedRuntimeReadinessReport`.

## Rule

Only `readiness.readiness_state == "ready"` and
`readiness.is_runnable == true` may enable cluster start.

`partial` means at least one warning or missing proof gate exists. `blocked`
means at least one hard error exists.

## Blocked Example

```json
{
  "node_id": "node-a",
  "device_name": "m5-max-a",
  "osaurus_version": "0.0-test",
  "osaurus_commit": "abcdef0",
  "vmlx_pin": "fcb69484105683c5a5032b97420d00e75d3a914e",
  "distributed_capability_version": 1,
  "roles": ["coordinator", "rankWorker"],
  "control_endpoints": ["m5-max-a.local:1337"],
  "data_plane_candidates": [
    {
      "raw_value": "10.20.0.1:29500",
      "host": "10.20.0.1",
      "port": 29500,
      "address_class": "thunderboltLoopback"
    },
    {
      "raw_value": "10.20.0.2:29500",
      "host": "10.20.0.2",
      "port": 29500,
      "address_class": "thunderboltLoopback"
    }
  ],
  "readiness": {
    "world_size": 2,
    "librdma_loadable": true,
    "jaccl_available": false,
    "ibv_devices_configured": false,
    "readiness_state": "blocked",
    "is_runnable": false,
    "endpoints": [
      {
        "raw_value": "10.20.0.1:29500",
        "host": "10.20.0.1",
        "port": 29500,
        "address_class": "thunderboltLoopback"
      },
      {
        "raw_value": "10.20.0.2:29500",
        "host": "10.20.0.2",
        "port": 29500,
        "address_class": "thunderboltLoopback"
      }
    ],
    "findings": [
      {
        "level": "info",
        "code": "thunderbolt_data_plane_address",
        "message": "10.20.0.1 is accepted as a Thunderbolt tensor data-plane address."
      },
      {
        "level": "info",
        "code": "thunderbolt_data_plane_address",
        "message": "10.20.0.2 is accepted as a Thunderbolt tensor data-plane address."
      },
      {
        "level": "error",
        "code": "jaccl_unavailable",
        "message": "JACCL is not available; distributed execution must stay disabled."
      },
      {
        "level": "error",
        "code": "ibv_devices_missing",
        "message": "MLX_IBV_DEVICES is not configured for the tensor-parallel ranks."
      }
    ]
  }
}
```

## Partial Examples

Private LAN, Wi-Fi, link-local, and localhost candidates must remain `partial`
unless a future explicit fabric policy proves them.

```json
{
  "readiness": {
    "world_size": 2,
    "librdma_loadable": true,
    "jaccl_available": true,
    "ibv_devices_configured": true,
    "readiness_state": "partial",
    "is_runnable": false,
    "endpoints": [
      {
        "raw_value": "192.168.1.20",
        "host": "192.168.1.20",
        "port": null,
        "address_class": "privateOther"
      }
    ],
    "findings": [
      {
        "level": "warning",
        "code": "unproven_data_plane_address",
        "message": "192.168.1.20 is privateOther, not a proven Thunderbolt tensor data-plane address."
      }
    ]
  }
}
```

## Ready Example

This is a policy-ready shape only. It is not a Qwen runtime proof unless the
runtime proof gate is also attached by a later implementation.

```json
{
  "readiness": {
    "world_size": 2,
    "librdma_loadable": true,
    "jaccl_available": true,
    "ibv_devices_configured": true,
    "readiness_state": "ready",
    "is_runnable": true,
    "endpoints": [
      {
        "raw_value": "10.20.0.1:29500",
        "host": "10.20.0.1",
        "port": 29500,
        "address_class": "thunderboltLoopback"
      },
      {
        "raw_value": "10.20.0.2:29500",
        "host": "10.20.0.2",
        "port": 29500,
        "address_class": "thunderboltLoopback"
      }
    ],
    "findings": [
      {
        "level": "info",
        "code": "thunderbolt_data_plane_address",
        "message": "10.20.0.1 is accepted as a Thunderbolt tensor data-plane address."
      },
      {
        "level": "info",
        "code": "thunderbolt_data_plane_address",
        "message": "10.20.0.2 is accepted as a Thunderbolt tensor data-plane address."
      }
    ]
  }
}
```

## UI Handling

- `blocked`: show the first hard error prominently and keep start disabled.
- `partial`: show the missing proof gate and keep start disabled.
- `ready`: enable start only if the selected mode also has the required
  runtime proof gate.
- Tailscale `100.x` is always control-plane only.
