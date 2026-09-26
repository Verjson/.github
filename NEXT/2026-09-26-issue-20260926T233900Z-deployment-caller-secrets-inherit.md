---
date: 2026-09-26
id: 20260926T233900Z
impact: minor
title: Generated container-deployment callers inherit the protected environment secret context (#1451)
---
`scripts/gen-container-deployment.sh` now emits `secrets: inherit` on each reusable edge it generates, and the generated contract test requires exactly that line while still rejecting any named secret, `secrets.` reference, `RUNNER_HOST_EVIDENCE_` name, or `environment:` binding in a caller. Adopters must regenerate the full caller set at this contract SHA; a caller without the inheritance now fails its own contract test.

The first CI-driven dry-run in `verjson-git-runners` (run 36279086275) reached the controller with all four `RUNNER_HOST_EVIDENCE_*` secrets empty although they exist in the caller's protected `production` environment, because an environment binding inside a reusable workflow never resolves the caller's environment secrets without inheritance (ADR 0171, actions/runner#4453). ADR 0198 is amended with the decision and its trade-off.
