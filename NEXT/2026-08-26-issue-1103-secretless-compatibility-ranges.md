---
date: 2026-08-26
issue: 1103
impact: minor
title: Resolve compatibility ranges through secretless Node CI
---

Let canonical Node CI resolve approved GitHub Packages ranges at run time, transfer exact verified tarballs with bound provenance, and run each compatibility lane without exposing acquisition credentials to consumer code.

The opt-in npm contract reuses the existing secretless package policy and bounded cache handoff, distinguishes authentication, access, missing-package, and empty-range failures, and rejects tampered provenance or content before consumer execution. ADR 0140 records the security boundary.
