---
date: 2026-10-01
issue: 1667
impact: patch
title: Index configurable OCI candidate destinations
---

Validates configurable GHCR and GAR candidate destinations, copies and reads back OCI indexes before issuing destination receipts, and binds expiry metadata to the published candidate. Nexus remains deferred until [verjson-ci#30](https://github.com/Verjson/verjson-ci/issues/30) provides multi-platform OIDC publishing.
