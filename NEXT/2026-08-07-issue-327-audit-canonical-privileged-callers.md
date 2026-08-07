---
date: 2026-08-07
issue: 327
title: Audit canonical privileged merge caller content
---

Make privileged-merge fleet conformance compare each consumer caller with the canonical generator output instead of accepting any file at the expected path.

The read-only audit now distinguishes missing, unreadable, undecodable, and drifted callers. This exposes obsolete hardcoded runner overrides without changing repository settings, organization secrets, rulesets, IAM, or consumer files.
