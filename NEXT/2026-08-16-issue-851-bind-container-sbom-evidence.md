---
date: 2026-08-16
issue: 851
impact: patch
title: Bind container SBOMs through the parent OCI index
---

Make generated container candidate callers executable and bind each signed SPDX document to one exact reviewed platform through BuildKit's parent-index evidence topology.

The SBOM publisher now receives exact GHCR write authority, while candidate assembly excludes `unknown/unknown` attestation descriptors from deployable platforms and fails closed on missing, duplicate, ambiguous, or unbound evidence ([ADR 0078](../docs/decisions/0078-container-release-and-runner-deployment-contract/README.md)).
