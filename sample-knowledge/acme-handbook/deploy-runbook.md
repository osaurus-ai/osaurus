---
type: guide
title: Production Deploy Runbook
description: How to cut and ship an Acme production release.
tags: [engineering, ops, deploy]
---

# Production Deploy Runbook

Follow this runbook to ship a release. **Note:** this document is intentionally
out of date so you can test the staleness → proposal → approval curation loop.

## Prerequisites

- You are on **macOS 12 (Monterey)** with **Xcode 14**. _(This is stale — the
  team moved to macOS 15 and Xcode 16 last quarter.)_
- You have push access to the release repository.

## Steps

1. Pull the latest `main` and confirm the build is green on **Jenkins**.
   _(Also stale — CI moved to GitHub Actions.)_
2. Bump the version number and tag the release.
3. Run the full test suite and wait for a clean pass.
4. Build the signed artifact and upload it to the distribution bucket.
5. Post the release notes in the engineering channel.

## Rollback

If a release misbehaves, re-deploy the previous tagged build and open an incident
in the tracker.
