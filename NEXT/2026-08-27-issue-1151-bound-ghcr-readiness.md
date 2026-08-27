---
date: 2026-08-27
issue: 1151
title: Bound GHCR readiness before provenance attestation
---

Require a newly pushed image digest to become visible through GHCR's OCI API
within a bounded retry window before attaching provenance, failing closed if
the registry never converges.
