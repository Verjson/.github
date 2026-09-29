---
date: 2026-09-29
issue: 1646
impact: patch
title: Require the generated CLI Projects CI caller
---

Pin the CLI Projects required workflow to the current generated caller. PR admission accepts only byte-exact `ci.yml` output from the generator bound by the immutable required-workflow SHA. The prior-main digest remains in `rollout_legacy_consumer_workflow_sha256` only so the ruleset rotation verifier can validate the existing default-branch caller; it is not embedded in or accepted by the PR workflow. Keep the strict `admission` status check and bind rollout verification to the exact head and required-workflow run. Strict freshness refreshes ordinary stale heads; safety no longer depends on a base advance invalidating a cached legacy result. After `Verjson/verjson-cli-projects#142` lands and `main` matches the generator, remove the rollout-only digest. Resolves #1646; see ADR 0212.
