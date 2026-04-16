# File Management Architecture Review And PR0

Date: `2026-04-16`

## Purpose

Osaurus already has the right instincts for file handling:

- conservative host-native import in `OsaurusCore`
- plugin-first growth for broader format coverage
- artifact sharing through the existing `share_artifact` flow
- a registry-backed import foundation that is already emerging upstream

What it does not have yet is a complete file-management standard.

`PR0` is the phase that turns "some file support" into a durable subsystem with
shared vocabulary, provenance, security limits, and review rules.

## Current Strengths

The current public queue already covers important ground:

- validation and PR hygiene
- registry-backed file import foundation
- safe host-native import expansion
- the first native plugin importer contract
- attached-document retrieval in local chat

That is a strong base. It is still missing the standard that future importers,
generators, and format packs must obey.

## Why PR0 Is Necessary

Without `PR0`, Osaurus risks accumulating:

- importer result shapes that do not match each other
- generators that cannot be traced back to their inputs
- inconsistent placement decisions between core, native plugins, and sandbox plugins
- security policy that exists only as habit instead of contract
- format packs that add dependencies without a repeatable review path

`PR0` is the standardization and hardening layer that prevents that drift.

## Design Principles

The file-management system should be built around a few durable rules:

1. Keep the core small.
   Core should only own cheap, host-native, low-risk file behaviors.
2. Make metadata and provenance first-class.
   Importers and generators should report what they saw, what they emitted, and
   how much was partial or truncated.
3. Separate contracts from implementations.
   The manifest, request, response, and failure vocabulary should stay stable
   even as implementations change.
4. Prefer deterministic fallbacks.
   Unsupported, malformed, oversized, or unsafe inputs should fail closed with a
   typed error instead of shelling out or guessing.
5. Grow by reviewable slices.
   Standardize first, then add format packs one family at a time.

## Capability Placement Matrix

Every future file capability should declare where it lives and why.

| Placement | Use For | Typical Examples | Not Allowed |
|---|---|---|---|
| `core` | cheap, host-native, low-risk handling | plain text, code/config text, PDF text extraction, HTML/RTF/DOCX summary extraction, lightweight metadata readers | heavy converters, OCR, shell-driven pipelines |
| `native_plugin` | deterministic higher-level import/export without sandbox-only dependencies | Office generation, data/database readers, CAD/BIM readers, domain-specific structured extraction | mutable-branch dependencies, ad hoc shell wrappers |
| `sandbox_plugin` | heavyweight tools, CLIs, OCR, model-assisted extraction, or risky converters | LibreOffice headless, Pandoc wrappers, OCR pipelines, archive inspection helpers | bypassing host limits or writing outside allowed output roots |

## PR0 Deliverables

`PR0` is complete only when these pieces exist:

### 1. Canonical contracts

- importer contract
- generator/export contract
- shared failure taxonomy
- shared provenance vocabulary

### 2. Canonical models

The substrate should converge on stable internal types for:

- `FileRecord`
- `FileSummary`
- `FileProvenance`
- `StructuredExtraction`
- `GeneratedArtifactRecord`

Minimum tracked facts:

- source path
- content hash
- size and modified timestamp
- detected type
- importer or generator identifier
- plugin identifier when applicable
- schema version
- truncation or partial-extraction flags
- elapsed time and warnings

### 3. Canonical governance

- placement rule: `core` vs `native_plugin` vs `sandbox_plugin`
- archive depth and nested-container policy
- regular-file and path-traversal enforcement
- dependency review template
- performance budgets for latency, memory growth, text output, and preview depth

### 4. Canonical validation

- malformed-input tests
- oversized-input tests
- security-path tests
- fixture corpora by format family
- benchmark harness and baseline budgets

## PR0 Implementation Chain

Keep `PR0` reviewable by splitting it into four public PRs:

### `PR0-A` Documentation and contracts

- architecture review and placement rules
- importer contract revision
- generator/export contract
- dependency review template
- phased rollout document

### `PR0-B` Core schema and provenance

- canonical file-management models
- lightweight SQLite catalog and provenance storage
- migration and fixture-backed tests

### `PR0-C` Security and limits

- archive-depth policy
- nested-container policy
- path-validation utilities
- regular-file enforcement
- shared import/generation error taxonomy

### `PR0-D` Conformance and benchmark harness

- fixture corpus layout by format family
- malformed and oversized fixtures
- benchmark commands and baseline metrics
- CI hooks for file-management PRs

## Acceptance Criteria

`PR0` is successful when:

- every importer and generator can be described with the same vocabulary
- every result can be traced back to a source file, tool, plugin, and schema version
- every new capability declares where it lives and why
- every future format pack adds fixtures and limits before implementation lands
- the system has explicit performance and security budgets

## Roadmap After PR0

After the substrate lands, format growth should stay plugin-first and follow a
clear pack order:

1. Office pack
2. Data and database pack
3. Technical and engineering pack
4. Mining and geoscience A
5. Mining and geoscience B
6. Scientific pack
7. Archive and system inspection pack

This keeps the core strict while still allowing Osaurus to become a remarkable
file operating layer over time.
