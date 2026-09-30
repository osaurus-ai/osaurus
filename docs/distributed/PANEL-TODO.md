# Distributed inference — Settings panel and execution checklist

No releases or tags from this lane. Native Swift/SwiftUI plus the bundled
C/C++ runtime. Reuse the Osaurus theme, settings catalog/anchors, per-host model
discovery and the shared Server cache configuration.

Legend: `[x]` implemented, unit-tested and exercised in a fresh isolated
Release build through the real UI (two M5 Max MacBook Pros, one Thunderbolt
cable, macOS 27.0); `[~]` implemented, proof pending; `[ ]` not implemented.

## Preview panel (this PR)

- [x] Settings → Distributed Inference sidebar tab (Models group), existing
      header/section/button/toggle primitives, stable telemetry token.
- [x] **This Mac**: computer name, Osaurus version, memory, `rdma_ctl status`,
      `ibv_devices` + `ibv_devinfo` port state (PORT_ACTIVE/PORT_DOWN).
- [x] **Thunderbolt Links** from `system_profiler -json SPThunderboltDataType`:
      receptacle → "Thunderbolt N" hardware port → BSD interface → `rdma_enN`,
      measured link rate, the directly cabled Mac (domain UUID, model, IP
      service). Docks and hosts behind a dock are *not* Mac-to-Mac links.
- [x] **Make This Mac Discoverable** (off by default, persisted, resumed at
      launch): `_osaurus-dist._tcp` via `NWListener`, TXT = node id, name,
      version, own TB domain UUIDs, RDMA state, memory, selected model +
      identity. The listener cancels every connection (no control plane yet).
      Declared in `NSBonjourServices`.
- [x] **Check for TB5 Nodes**: 8 s bounded `NWBrowser` scan with cancel;
      callbacks from a replaced/cancelled browser are dropped; typed Local
      Network denial. **Cable verified** only when the peer's own domain UUID
      is the host cabled to one of this Mac's ports (reciprocal-domain check).
      Interfaces the advert arrived on are shown (Wi-Fi vs Thunderbolt Bridge).
- [x] **Distributed Model** from the shared catalog
      (`ModelManager.discoverLocalModelsOffMain`: Osaurus models folder +
      imported LM Studio/HF/custom bundles), deduplicated, refreshed on
      `.localModelsChanged`; unavailable selection shown explicitly.
- [x] Bundle identity: SHA-256 over config, generation config, tokenizer,
      tokenizer config, chat template, JANG/quant metadata, shard index and
      every shard's safetensors header. Payload bytes not hashed (stated in UI).
      Missing/unreadable shards reported. Peer comparison uses the advertised
      short fingerprint (unauthenticated hint).
- [x] Head divisibility arithmetic for 2 and 4 Macs (attention, KV, linear
      key/value heads) — arithmetic only, not a sharding plan.
- [x] **SSD Cache**: configured runtime directory (shared Server settings),
      symlinks resolved including dangling ones, mount identity (a
      `/Volumes/<name>` path must be that mount point), volume, APFS physical
      store, bus, internal/external, SSD flag, network volume, free/total,
      effective quota via `ModelRuntime.diskCacheCap`, indexed bytes used via
      `DiskCacheVolumeSnapshot`. Never creates the folder.
- [x] **Setup & Permissions** checklist (cable, RDMA, Local Network, peers,
      cache), Setup Guide sheet, Local Network privacy + System Settings links.
      Nothing is enabled, installed or restarted by Osaurus.
- [x] Search catalog: 16 rows with exact titles, disambiguation from *Share my
      models for inference*, anchors on every control, self-find labels, guide.
- [x] Focused unit suites (real two-Mac Thunderbolt/ibv fixtures): see
      `Tests/Distributed/`.
- [x] Fresh isolated Release build + focused test runs (21 suites).
- [x] Native GUI proof via pid-scoped Accessibility actions: every control,
      scan/cancel/rescan, discoverable on/off (independent DNS-SD observer) and
      relaunch persistence, model select/persist, pending macOS permission
      states, Configure SSD Cache landing, Finder reveal, disk-image cache
      mounted/ejected/reattached, external SSD, disk cache disabled, search →
      scroll/glow, Setup Guide, privacy link, light/dark, minimum/large window,
      repeated full-tree AX traversal.
- [x] Two-Mac discovery with the same build on both cabled Macs: Cable
      verified, RDMA state, same bundle identity from different model folders.

## Known limitations of the preview (must stay visible)

- Adverts are unauthenticated. A cable match is physical evidence, not trust.
- No rank worker, control plane, pairing or tensor transport exists.
- Head arithmetic ≠ sharding support. Qwen Flash Next (`qwen4_exp`) sharding,
  PLE, recurrent state and mixed-bit quant slicing are not implemented.
- Cache panel shows this Mac only; per-rank namespaces/usage not wired.
- The runtime's own disk-cache probe still relies on `/Volumes` being
  root-owned to avoid writing into a stale mountpoint directory; the panel
  detects that case, the runtime does not yet (see follow-ups).
- macOS 27 offers no public deep link to the Local Network privacy pane; the
  button opens Privacy & Security and says to choose Local Network.
- Local Network access cannot be queried directly; it is reported "Allowed"
  only after this Mac sees its own (or a peer's) advertisement.

## Before distributed execution (follow-up PRs)

- [ ] Authenticated pairing (identity keys), version/engine-pin handshake,
      control plane on the verified wired interface only.
- [ ] Signed embedded rank worker; typed init/split errors that never reach the
      global MLX fatal handler; strict requested vs actual rank/world checks
      before model load; size-1 fallback never reported as TP.
- [ ] Per-peer model identity exchange over the authenticated channel; each rank
      resolves from its own configured model folder; mismatch blocks launch.
- [ ] RDMA topology from both ends (PORT_ACTIVE on the cabled `rdma_enN`),
      no Wi-Fi/tailnet substitution for tensor traffic.
- [ ] `qwen4_exp` mixed-JANG sharding, recurrent/PLE state, KV replication for
      world > 2, single- vs multi-rank logit parity.
- [ ] Cache keys include rank/world/shard/model identity; per-rank quota and
      eviction; ejected volume stops writes on every rank.
- [ ] Runtime disk-cache probe: reject a `/Volumes/<name>` directory that is not
      its own mount point (shared classifier with the panel).
- [ ] Start/stop/cancel/failure/rejoin settle every rank; stale readiness is
      invalidated; real two-Mac collectives, multi-turn, TTFT/tok/s, footprint.
