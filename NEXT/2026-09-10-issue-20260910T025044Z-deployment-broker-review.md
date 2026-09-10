---
date: 2026-09-10
id: 20260910T025044Z
impact: patch
title: Preserve renamed repository provenance and strict receipt types
---

Separate the deployment broker's current API repository name and stable ID from historical signed-source identity. The exact runner v0.2.1 manifest proves renamed repositories retain strict source and signer verification. Reject numeric health flags, Boolean attempts and floating-point IDs at receipt and API boundaries; adversarial tests and ADR 0170 record both review corrections.
