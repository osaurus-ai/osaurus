# File Import Phased PR Plan

Date: `2026-04-16`

This document turns the file-management roadmap into reviewable PR slices that
fit Osaurus development guidelines:

- keep `OsaurusCore` conservative
- prefer plugin-first capability growth
- standardize before broadening coverage
- one public PR per initiative
- one test plan and one security story per PR

Related documents:

- [Development Docs Index](./README.md)
- [File Management Architecture Review And PR0](./FILE_MANAGEMENT_ARCHITECTURE_REVIEW_AND_PR0.md)
- [File Import Plugin Contract](./file-import-plugin-contract.md)
- [File Generator And Export Contract](./file-generator-export-contract.md)
- [Dependency Review Template](./file-management-dependency-review-template.md)
- [Plugin Authoring Guide](../PLUGIN_AUTHORING.md)

## Current Baseline

The public queue already established the direction:

- validation gate
- registry-backed import foundation
- safe host-native import expansion
- native plugin importer contract
- attached-document retrieval

The next wave should not jump straight to format packs. It should standardize
the substrate first.

## `PR0` Chain

### `PR0-A` Documentation and contracts

Scope:

- architecture review and placement rules
- importer contract revision
- generator/export contract
- dependency review template
- phased rollout plan

Goal:

- freeze the vocabulary before code growth continues

### `PR0-B` Core schema and provenance

Scope:

- canonical file-management models
- lightweight SQLite catalog and provenance store
- migration and fixture-backed tests

Goal:

- give importers and generators a common record model

### `PR0-C` Security and limits

Scope:

- archive-depth policy
- nested-container policy
- path-validation utilities
- regular-file enforcement
- shared error taxonomy

Goal:

- make the governance layer explicit and reusable

### `PR0-D` Conformance and benchmark harness

Scope:

- fixture corpus layout by format family
- malformed and oversized fixtures
- benchmark commands and baseline metrics
- CI hooks for file-management PRs

Goal:

- make future format packs measurable, not anecdotal

## Parallelism Rules

Public publication should remain ordered:

1. `PR0-A`
2. `PR0-B`
3. `PR0-C`
4. `PR0-D`

Safe overlap:

- `PR0-B` model design and DB scaffolding can be prepared in parallel once
  `PR0-A` freezes the vocabulary.
- `PR0-C` policy drafting can start alongside `PR0-B`, but it should not land
  first because it depends on the shared contract language.
- `PR0-D` fixture taxonomy can be drafted early, but the harness should land
  only after `PR0-B` and `PR0-C` settle the result and policy shapes.

Implementation boundary for `PR0`:

- keep the substrate inside the existing `Packages/OsaurusCore` target for now
- treat `DocumentParser` as a compatibility surface until a later migration PR
- avoid moving unrelated UI call sites during `PR0`

## Format Packs After `PR0`

When `PR0` is merged, land the packs in this order:

1. Office
   - `xlsx`, `xls`, `pptx`, `ppt`, `odt`, `ods`, `odp`, `epub`, `eml`, `ics`, `vcf`
   - exports: `pptx`, `xlsx/csv`, `html`, `pdf`
2. Data and database
   - `sqlite`, `duckdb`, `parquet`, `arrow`, `feather`, `avro`, `msgpack`, `bson`
   - exports: `csv`, `xlsx`, `json`, `html`, `pdf`
3. Technical and engineering
   - `dxf`, `step/stp`, `iges/igs`, `stl`, `obj`, `gltf/glb`, `usdz`, `ifc`, `gerber`, `drl`, `gcode`, `spice`
4. Mining and geoscience A
   - `las`, collar/survey/assay/lithology tables, `geojson`, `kml`, `kmz`, `gpx`, `gpkg`, `geotiff`
5. Mining and geoscience B
   - `dlis`, `lis`, `segy`, `shp/shx/dbf`, `omf`, selected block-model/vendor interchange formats
6. Scientific
   - `netcdf`, `hdf5`, `fits`, `mat`, `rds`, `rda`, `RData`, `ipynb`
7. Archive and system inspection
   - `tar`, `gz`, `bz2`, `xz`, `zst`, `lz4`, optional `7z`/`rar`, `iso`, `dmg` metadata, `warc`, `pcap`, `pcapng`

## Review Rules For Every Future Pack

- keep scope to one format family only
- add malformed and oversized fixtures before capability code lands
- document every dependency and why it belongs in `core`, `native_plugin`, or `sandbox_plugin`
- keep prompt integration on existing attached-document and artifact paths unless a separate host redesign is approved
- require `share_artifact` for user-visible generated files
