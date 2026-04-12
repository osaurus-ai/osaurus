# File Import Phased PR Plan

This document turns the file-format roadmap into reviewable PR slices that fit
Osaurus development guidelines:

- keep `OsaurusCore` conservative
- prefer plugin-first capability growth
- one phase = one focused branch
- one phase = one test plan
- one phase = one security checklist
- one phase = one PR

Related documents:

- [Development Docs Index](./README.md)
- [Project State And Forward Plan](./PROJECT_STATE_AND_FORWARD_PLAN.md)
- [File Import Plugin Contract](./file-import-plugin-contract.md)
- [Plugin Authoring Guide](../PLUGIN_AUTHORING.md)
- [Sandbox Guide](../SANDBOX.md)
- [Phased Development Plan](./work-mode-reliability/00_PHASED_DEVELOPMENT_PLAN.md)

## Current Status

The host-side foundation now exists locally:

- registry-backed importer resolution
- built-in importer registration in `OsaurusCore`
- async compatibility bridge through `DocumentParser`
- native plugin manifest support for `capabilities.file_importers`
- plugin lifecycle registration and unload hooks

That foundation should be treated as the prerequisite PR for all later format packs.

## PR Sequence

### PR 0 — Import Foundation

Goal:
- land the host architecture required for all later importers

Scope:
- `FileImportDescriptor`
- `FileImportRegistry`
- `FileImportService`
- async `DocumentParser` bridge
- plugin manifest `file_importers`
- plugin contract documentation

Acceptance:
- existing attachment UX remains intact
- built-in text, document, and PDF import still work
- plugin-backed importers can be declared without further host schema changes

Suggested branch:
- `codex/file-import-foundation`

### PR 1 — Core Safe Expansion

Goal:
- expand low-risk built-in read coverage without adding heavy dependencies

Scope:
- `jsonl`
- `ndjson`
- `svg`
- `plist`
- tighter size and truncation tests
- optional metadata-only readers for image/audio/video if they stay host-native

Acceptance:
- all formats normalize to existing `.document` attachments
- no new dependency or shell-based parser required

Suggested branch:
- `codex/file-import-core-safe-expansion`

### PR 2 — Office Import Plugin Pack

Goal:
- first real plugin pack using the new contract

Scope:
- read: `xlsx`, `xls`, `pptx`, `ppt`, `odt`, `ods`, `odp`, `epub`, `eml`, `ics`, `vcf`
- write/export: `pptx`, `xlsx/csv`, `html`, `pdf`
- plugin-local generator state
- `SKILL.md` describing generation workflow

Acceptance:
- unsupported office files route through the office plugin when installed
- absent plugin fails cleanly
- generation outputs are shared through `share_artifact`

Suggested branch:
- `codex/file-import-office-pack`

### PR 3 — Data And Database Plugin Pack

Goal:
- structured data and analytical file support

Scope:
- `sqlite`, `db`, `sqlite3`
- `duckdb`
- `parquet`
- `arrow`, `feather`
- `avro`
- `msgpack`
- `bson`
- exports: `csv`, `xlsx`, `json`, `html`, `pdf`

Suggested branch:
- `codex/file-import-data-pack`

### PR 4 — Technical And Engineering Plugin Pack

Goal:
- engineering and CAD inspection workflows

Scope:
- `dxf`
- `step`, `stp`, `iges`, `igs`
- `stl`, `obj`, `gltf`, `glb`, `usdz`
- `ifc`
- `gerber`, `drl`
- `gcode`
- `spice`
- exports: `json`, `html`, `pdf`, previews

Suggested branch:
- `codex/file-import-technical-pack`

### PR 5 — Mining And Geoscience Pack A

Goal:
- start with mining formats that are already text- or table-friendly

Scope:
- `las`
- collar, survey, assay, lithology tables
- `geojson`, `kml`, `kmz`, `gpx`, `gpkg`, `geotiff`
- reporting extraction from `pdf`/`docx`
- exports: `csv`, `json`, `html`, `pdf`, `xlsx`

Suggested branch:
- `codex/file-import-mining-pack-a`

### PR 6 — Mining And Geoscience Pack B

Goal:
- harder binary and vendor-adjacent mining formats

Scope:
- `dlis`
- `lis`
- `segy`
- `shp`, `shx`, `dbf`
- `omf`
- block model exports
- selected vendor interchange formats

Suggested branch:
- `codex/file-import-mining-pack-b`

### PR 7 — Scientific Plugin Pack

Goal:
- scientific dataset coverage with analyst-friendly exports

Scope:
- `netcdf`
- `hdf5`
- `fits`
- `mat`
- `rds`, `rda`, `RData`
- `ipynb`
- optional `root`

Suggested branch:
- `codex/file-import-scientific-pack`

### PR 8 — Archive And System Inspection Pack

Goal:
- close remaining inspection-format gaps without bloating core

Scope:
- `tar`, `gz`, `bz2`, `xz`, `zst`, `lz4`
- optional `7z`, `rar`
- `iso`
- `dmg` metadata and safe inspection
- `warc`
- `pcap`, `pcapng`
- executable/container inventories

Suggested branch:
- `codex/file-import-archive-pack`

## PR Rules

For every PR:

- keep scope to one phase only
- include fixtures only for that phase’s formats
- include at least one malformed-input test
- include at least one oversized-input test
- document every new dependency and why it belongs in core vs plugin
- keep prompt integration on existing `<attached_document ...>` unless a separate host redesign PR is approved

## Clean Development Setup

Recommended local layout:

- main local checkout:
  - keep for integration work only
- clean file-import worktree:
  - create from `upstream/main`
  - use for the public PR branch only
- optional plugin-pack worktrees:
  - one worktree per plugin pack if phases overlap

Suggested worktree names:

- `.local-worktrees/file-import-foundation`
- `.local-worktrees/file-import-office`
- `.local-worktrees/file-import-data`
- `.local-worktrees/file-import-mining-a`
- `.local-worktrees/file-import-scientific`

Do not use the current dirty local integration checkout as the source of an upstream PR.
