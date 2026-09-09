---
date: 2026-09-09
issue: 629
impact: patch
title: Bind runner deployments to the exact attested release asset bytes
---

Runner deployments accept the original UTF-8 release manifest bytes and verify their digest against the attestation and selected release identity. This fixes admission of published manifests whose whitespace differs from compact JSON, while preserving exact identities during rollback, resume, and reconciliation and rejecting tampered or ambiguous evidence.

The regression suite includes the unchanged public v0.2.1 runner release asset. ADR 0078 records the restored invariant, compatible canonical-byte fallback, and evidence adapter contract.
