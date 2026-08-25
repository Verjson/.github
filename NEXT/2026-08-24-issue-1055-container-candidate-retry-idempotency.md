---
date: 2026-08-24
issue: 1055
impact: patch
title: Make container candidate retries idempotent
---

Reuse an existing exact-commit container image only after its complete platform index and provenance are cryptographically bound to the reviewed repository, source commit, canonical workflow, and immutable contract.

Malformed, partial, mismatched, unprovenanced, or unreadable state fails closed while the divergent immutable-tag guard remains unchanged ([ADR 0078](../docs/decisions/0078-container-release-and-runner-deployment-contract/README.md)).
