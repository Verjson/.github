---
date: 2026-08-12
issue: 743
title: Isolate scheduled workflow checkouts
---

Isolate scheduled workflow checkouts by run, attempt, and job, and contain sparse checkouts so reused runner workspaces cannot corrupt later jobs.

Commands now run inside their isolated source directory, exact-path cleanup prevents residue,
and semantic conformance tests preserve the boundary. See ADR 0096.
