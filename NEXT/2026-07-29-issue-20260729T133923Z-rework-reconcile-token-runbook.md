---
date: 2026-07-29
id: 20260729T133923Z
title: Document how to provision REWORK_RECONCILE_TOKEN
---

The weekly rework reconciler has been reporting seven of its eight configured
repos as degraded (`commit data unavailable`) because the Actions secret
`REWORK_RECONCILE_TOKEN` is unset and the job falls back to this repo's
`GITHUB_TOKEN`. The workflow wiring was already correct
(`.github/workflows/rework-reconcile.yml:40`); what was missing was a runbook, so
the org admin had to re-derive the token's scope from the script every time.

`docs/rework-telemetry.md` now carries a *Provisioning `REWORK_RECONCILE_TOKEN`*
section: the exact least-privilege permission set read off the calls in
`scripts/ci-telemetry/rework-reconcile.sh` (Metadata, Pull requests, Contents —
all **read**, nothing else and no write scope of any kind), the eight repositories
from `.telemetry/rework-thresholds.json`, the `gh secret set` command, and the
re-run-and-check-for-no-warning verification step. It states explicitly that the
credential must stay read-only so the reconciler cannot influence a merge or
verification gate, preserving the ADR 0006 observe-and-report boundary.

Docs only — no behaviour change. The degraded path was exercised against a stubbed
`gh` whose commits call fails, and it correctly emits the `commit data unavailable`
banner and exits 0 rather than swallowing the failure, so there was nothing to fix
in the script. Minting the credential is human-only (no API), so #157 stays open
until an org admin runs the runbook. Refs #157, #150, ADR 0006.
