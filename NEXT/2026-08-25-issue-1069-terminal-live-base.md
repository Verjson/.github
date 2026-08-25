---
date: 2026-08-25
issue: 1069
impact: patch
title: Bind terminal merges to the live default-branch commit
---

Terminal promotion now rejects stale generated publications by binding authorization and the repository-scoped merge App's final pre-merge checks to the same trusted default-branch commit.

ADR 0133 records the API-derived trust boundary, exact repository and permission confinement, fail-closed race handling, and GitHub's lack of an atomic expected-base merge parameter.
