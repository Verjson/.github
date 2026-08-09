---
date: 2026-08-09
issue: 680
title: Add secretless Node pull-request validation for approved private dependencies
---

Add an opt-in canonical Node CI route that acquires allowlisted internal dependencies without lifecycle scripts, then executes pull-request code in a separate job without package, Git, cloud, or OIDC credentials ([ADR 0086](../docs/decisions/0086-secretless-node-pr-validation/README.md)).

Existing callers retain their credentialed installation path. Secretless callers omit `packages: read`, explicitly map only the package acquisition token, and enumerate every approved `@verjson` dependency.
