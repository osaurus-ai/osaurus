# File Management Dependency Review Template

Use this checklist for every `PR0` follow-up and every future format-pack PR
that adds or expands a dependency.

## Summary

- Dependency name:
- Version / source:
- Placement:
  - `core`
  - `native_plugin`
  - `sandbox_plugin`
- Formats covered:
- Why this dependency is needed:

## Placement Justification

- Why does this belong in the chosen placement?
- Why does it not belong in `core`?
- If it is in `core`, why is it cheap, host-native, and low-risk?

## Runtime Footprint

- Added binary size or package weight:
- System packages required:
- Extra model, OCR, or CLI runtime requirements:
- Expected memory or latency cost:

## Security Review

- Does it shell out?
- Does it read archives or nested containers?
- Does it write files?
- Does it parse untrusted binary formats?
- What regular-file, path, and output-root checks are required?

## Supply Chain Review

- Immutable release or tag:
- License:
- Maintenance status:
- Known CVEs or ecosystem concerns:
- Why an existing dependency does not already solve this need:

## Validation Requirements

- Focused unit tests added:
- Malformed-input fixtures added:
- Oversized-input fixtures added:
- Security-path tests added:
- Benchmark or performance smoke added:

## Decision

- Approved placement:
- Follow-up limits or guardrails:
- Reviewer sign-off:
