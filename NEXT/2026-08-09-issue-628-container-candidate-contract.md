---
date: 2026-08-09
issue: 628
title: Add immutable container candidate publication contract
---

Add the canonical reusable workflow, generator, semantic validator, and generated contract test for complete, attested, digest-addressed container candidates on successful default-branch builds.

The PR path remains build-only, while publication is limited to the reviewed GHCR namespace and emits unique SemVer prerelease identities without stable promotion or deployment. ADR 0078 records the sensitive permission and provenance boundary.
