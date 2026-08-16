---
date: 2026-08-16
issue: 847
impact: patch
title: Attest and serialize canonical container promotion
---

Canonical container publication now signs every platform SPDX document and the release manifest, verifies exact producer identities, serializes releases, and reconciles the complete alias set before durable publication.

Generated candidate and release artifact sets carry the least attestation authority and pinned verifier needed to reject missing or substituted evidence. Candidate and release manifests advance to schema version 2 under the amended container delivery decision.
