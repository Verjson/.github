# 0068 — The merge dispatcher honors the caller’s explicit runner fleet

- **Date:** 2026-08-07
- **Issue:** [Verjson/.github#411](https://github.com/Verjson/.github/issues/411)
- **Category:** privileged workflow routing (sensitive)
- **Status:** Accepted
- **Amends:** ADR 0057 (`runner_labels` is optional but remains explicit
  cross-organization fleet authority)

## Context

The reusable merge gate accepts `runner_labels` for a self-hosted consumer whose
organization has no `VERJSON_LANE_*` variables. ADR 0057 made the input optional
again, while preserving it as the explicit escape hatch for that consumer.

`preflight` and `gate` gave the input first precedence. `dispatch-merge` did not.
An off-Verjson consumer could therefore request its own fleet, run validation
there, then silently run the metadata-only merge dispatcher on
`ubuntu-24.04`. That split violated the input’s meaning and could conflict with
the consumer’s funding or hosted-runner policy.

## Decision

`dispatch-merge` uses the same first term as `preflight` and `gate`:

```yaml
inputs.runner_labels && fromJSON(inputs.runner_labels)
```

A supplied value wins for public, private, unresolved, and external targets.
When the input is absent, the existing visibility and lane routes are unchanged:
public Verjson targets use the fast lane, private and unresolved Verjson targets
use the privileged/overflow lane chain, and external callers retain the portable
hosted default.

The input is caller fleet authority, not pull-request data. It is supplied by
the trusted reusable-workflow caller definition, and it cannot be set by a PR’s
title, body, branch, or changed files.

## Security boundary

This moves the metadata-only dispatcher, which has `contents: read` and
`actions: write`, onto the caller-selected runner. It does not move
`ORG_ADMIN_TOKEN`:

- `dispatch-merge` receives only the run-scoped `github.token`.
- It checks out no code, downloads no artifact, evaluates no PR prose, and can
  dispatch only the fixed `ai-privileged-merge.yml` continuation in
  `TARGET_REPO`.
- `ORG_ADMIN_TOKEN` remains bound once, in that fixed continuation. Its own
  `runner_labels` precedence and runner-admission boundary are governed by ADR
  0057 and ADR 0064.

The caller already selected the same runner for `preflight` and `gate`; applying
that request consistently to the smaller dispatcher grants no unintended runner
class authority beyond the explicit request.

## Consequences

- Self-hosted-only consumers no longer split one gate run across their fleet and
  an unrequested hosted runner.
- Verjson callers that omit `runner_labels` keep every current fast,
  overflow, and lane route.
- A caller that deliberately selects a compromised runner can use the scoped
  Actions token available to the dispatcher. That authority is inherent in the
  explicit fleet request and remains bounded to the fixed continuation.

## Verification

- `scripts/ci-gate/runner-routing-policy.test.sh` semantically evaluates supplied
  and absent input across public, private, unresolved, and external cases.
- `scripts/ci-gate/reusable-workflow.test.sh` requires the input to lead all
  three job selectors.
- `scripts/ci-gate/dispatch-permission.test.sh` pins the dispatcher to
  `github.token`, rejects secret references and PR-controlled execution, and
  preserves its minimal permissions.
