---
date: 2026-08-25
issue: 999
impact: patch
title: Match required-check commands by strict shell semantics
---

Accept harmless quoting and horizontal-spacing changes in the canonical changelog-contract job while continuing to reject changed variables, redirects, arguments, scripts, command boundaries, appended commands, and job-level permission overrides.

The workflow inspector now normalizes only the two exact command forms it owns instead of comparing their source strings byte-for-byte.
