---
date: 2026-08-08
issue: 608
title: Make merge-gate review pagination portable
---

Collect paginated prior-review responses with jq so public adopter runners whose GitHub CLI predates `gh api --slurp` can publish a non-blocking gate verdict while API and payload failures remain fail-closed.

The failing run already had `pull-requests: write`; the unsupported CLI flag prevented the request. This preserves the permission boundary and stale-review validation recorded in ADR 0058.
