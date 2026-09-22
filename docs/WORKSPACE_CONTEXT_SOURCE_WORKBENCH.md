# Workspace Context Source Workbench

The Workspace Context Source Workbench is the user-visible inventory for
context that can influence a workspace chat turn. It tracks descriptors for:

- Files, including uploaded attachments and workspace knowledge index entries.
- Memory.
- Agent DB.
- Sandbox context.
- Screen context.
- Citation-only carriers.

The workbench is metadata-only. It does not read memory facts, Agent DB rows,
file bytes, sandbox payloads, or screen-capture payloads. Those systems remain
the source of truth for hidden context and injection. Callers pass
`WorkspaceContextSourceInput` descriptors, and the workbench reports boundaries,
enablement, provenance, citations, dedupe, and freshness.

## Frozen Snapshots

Sandbox context and screen context require frozen snapshot metadata before they
are considered current. A source is marked stale when snapshot metadata is
missing, live instead of frozen, captured for a different source version, or
older than the source modification time.

Frozen snapshot provenance is intentionally small:

- `snapshotId` identifies the owner-system snapshot.
- `capturedAt` and `frozenAt` describe the source-owner freeze point.
- `sourceVersion`, `citationVersion`, and `contextDigest` let the workbench
  detect stale descriptors without copying payloads.

## Toggles

The policy layer supports:

- Enabled source kinds by active agent.
- Global per-source disables by source id or provenance stable id.
- Agent-scoped per-source disables by source id or provenance stable id.

Disabled sources remain visible in the inventory with warnings. They are not
included in `effectiveSources`.

## Citations

Citations are validated as anchors only. The workbench checks that citation ids,
referenced source ids, anchors, and cited source versions are stable. It does
not dereference or duplicate cited payloads.
