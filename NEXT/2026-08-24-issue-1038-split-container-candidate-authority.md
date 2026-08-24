---
date: 2026-08-24
issue: 1038
impact: major
title: Split container candidate validation and publication authority
---

Container candidate pull-request validation and trusted publication now use separate source-fixed reusable workflows, allowing GitHub to admit the read-only graph without granting package, attestation, or OIDC write authority.

ADR 0124 binds generated callers and provenance to both entrypoints at one immutable SHA. Candidate builder identity now names the publication workflow that actually exercises write authority.
