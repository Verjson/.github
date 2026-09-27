---
date: 2026-09-27
id: 20260927T023000Z
impact: minor
title: Verifier predicates for signed merge-gate provenance, derived from a captured private-consumer required-workflow token (#1339)
---
`scripts/ci-gate/merge-gate-provenance-claims.py` implements the exact predicates a signing rollout must enforce to bind a gate run to the canonical required workflow rather than the consumer's execution: issuer, organization id, `job_workflow_ref` on the canonical file at `refs/heads/main` **and** `job_workflow_sha` equal to the ruleset's stored commit, `workflow_ref`/`workflow_sha` identical to that pair (an injected required workflow, not a consumer-authored reusable call), `pull_request` event and `sub`, and a reviewed runner lane. `config/merge-gate-provenance-fixtures.json` carries the redacted genuine claim set captured from a real required-workflow run in the private scratch repository plus nine tampered variants; the registered test holds the genuine capture green and each variant red on its own predicate. The temporary probe workflow is deleted. ADR 0211 supersedes ADR 0077's residual risk as a specification; no signing is rolled out.
