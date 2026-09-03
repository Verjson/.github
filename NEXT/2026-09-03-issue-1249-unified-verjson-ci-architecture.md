---
date: 2026-09-03
issue: 1249
impact: major
title: Unify the portable CI engine and forge adapters
---

Adopt one versioned `verjson-ci` repository for the portable engine, CLI, OCI image,
GitHub and GitLab adapters, local and remote parity, OIDC-secured coordination, ShadScan,
signed releases, and external GitLab mirroring.

ADR 0162 supersedes ADR 0161's rejection of a unified engine while retaining its measured
cutover, trust-boundary, rollback, and cost requirements.
