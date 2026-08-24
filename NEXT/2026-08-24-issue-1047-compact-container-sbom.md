---
date: 2026-08-24
issue: 1047
impact: patch
title: Compact complete container SBOM predicates
---

Serialize complete platform SPDX documents as compact JSON so large container candidates remain within GitHub's 16 MiB attestation boundary without dropping package evidence.

The canonical helper retains exact platform and SPDX 2.3 identity checks and fails closed when the compact document itself remains oversized ([ADR 0078](../docs/decisions/0078-container-release-and-runner-deployment-contract/README.md)).
