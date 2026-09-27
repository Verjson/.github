# 0206 — Enroll the AI authorization arm with an independent property

- **Date:** 2026-09-23
- **Status:** Accepted
- **Issue:** [#1363](https://github.com/Verjson/.github/issues/1363)
- **Supersedes in part:** [ADR 0186](../0186-required-checks-bind-through-repository-properties/README.md)
- **Category:** ruleset enforcement

## Context

The organization ruleset `ai-authorization-arm-required` (`20722935`) selects
repositories through `verjson-core-checks=enforced`. That property also selects the
stack-specific deterministic CI rulesets. One property therefore means both “require
canonical core checks” and “run the AI authorization arm,” even though either contract
can evolve independently.

The overloaded selector makes adoption misleading and creates latent activation risk:
enabling deterministic CI can silently add the authorization workflow. It also prevents
an auditor from determining which contract an administrator intended to adopt.

Live organization metadata on 2026-09-23 showed 29 repositories selected by
`verjson-core-checks=enforced` and no `verjson-ai-authorization` schema. The migration
must preserve that reviewed cohort without briefly disarming it or expanding it.

## Decision

Create the optional organization property `verjson-ai-authorization` as a
`single_select` with `enforced` and `disabled` values, no default, and values editable
only by organization actors. Ruleset `20722935` selects only
`verjson-ai-authorization=enforced` after migration.

Authorization enrollment remains fail-closed against deterministic CI: every armed
repository must also carry `verjson-core-checks=enforced` and a supported
`verjson-stack`. The properties are independent selectors, not independent safety
requirements.

The reviewed migration cohort is recorded exactly in
`config/ai-review-required-workflow-rollout.json`. Apply the transition in this order:

1. Create the property schema with `PUT /orgs/Verjson/properties/schema/verjson-ai-authorization`.
2. Assign `enforced` to the reviewed cohort with one
   `PATCH /orgs/Verjson/properties/values` request.
3. Replace ruleset `20722935` with the reviewed image that selects the new property.
4. Read back the schema, values, and ruleset, then run the complete authorization-arm
   audit.

The audit recognizes the exact legacy selector and exact target selector, rejects any
third image, and requires the target cohort to equal the reviewed migration list. The
ruleset renderer is unavailable until both the exact schema and exact property cohort
are visible, so a partial values update cannot produce a disarming cutover payload.

The full forward preflight remains blocked by
[#1401](https://github.com/Verjson/.github/issues/1401) while any armed repository lacks
canonical deterministic CI. The dependency is intentional: the migration must not make
an already unsafe authorization cohort look ready by suppressing that finding.

The tool is deliberately read-only: render modes produce reviewed payloads but never
call a mutating API. Live application remains a separately authorized operator action
recorded on #1363.

Rollback can render the reviewed legacy selector from an exact target-selector state
even when the property schema or assignments are incomplete. Restore that selector
first. Only after readback confirms the legacy selector may the tool render the cohort
payload that unsets the dedicated values. Read back the unset values, then delete
`/orgs/Verjson/properties/schema/verjson-ai-authorization`. Deleting the schema before
restoring the selector is forbidden because it would leave the active ruleset referencing
an absent property.

## Consequences

- Core-check adoption no longer silently enrolls a repository in AI authorization.
- The current 29-repository authorization cohort is preserved deliberately.
- Adding or removing an armed repository requires an explicit property change and a
  matching reviewed migration-cohort update.
- The dedicated property is organization-controlled, so repository content and pull
  requests cannot self-enroll or self-disarm.
- ADR 0186 remains authoritative for deterministic status-check enrollment; only its
  statement that `verjson-core-checks` also selects the authorization arm is superseded.

## Verification

- `python3 scripts/ai_review_required_workflow_audit_test.py`
- `python3 scripts/ai-review-required-workflow-audit.py`
- In the legacy state, render and inspect schema, values, and ruleset payloads in order.
- In the target state, render the legacy-selector rollback; after restoring it, render
  the unset-values cleanup payload.
