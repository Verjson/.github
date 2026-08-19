---
date: 2026-08-19
issue: 702
title: Confirm the AI-review App's permission envelope was never the defect
---

The authorization App's `403 Resource not accessible by integration` errors were traced through several layers — missing Contents access, a GraphQL head lookup under the wrong token, an ambient `GH_TOKEN` alias shared between the workflow and App tokens — and fixed incrementally (App-level Contents permission, REST head lookup, explicit per-call App-token binding, phase-specific diagnostics). The installation's own permission envelope (`checks: write`, `contents: read`, `pull_requests: write`, `repository_selection: all`) was correct throughout; ADR 0079 is amended with the dated correction rather than superseded, since no decision changed.

Live proof: `Verjson/toquorum#596` produced three independent exact-head `verjson-ai-review-authorization[bot]` `APPROVE` reviews, each with a `success` authorization check and a successful promotion dispatch. This closes #702 and `Verjson/toquorum#558`. A separate, unrelated defect found while reproducing this — a consumer caller pinned to a contract SHA that predates `deepseek` provider support, now failing closed with `unsupported review provider` — is tracked as #933.
