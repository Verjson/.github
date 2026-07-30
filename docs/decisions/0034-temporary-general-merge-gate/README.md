# 0034 — Temporarily route Verjson merge gates through general runners

- **Date:** 2026-07-29
- **Issue:** [Verjson/.github#204](https://github.com/Verjson/.github/issues/204)
- **Temporarily supersedes:** ADR 0033 for AI merge-gate routing only

## Context

The GCP gate and isolated pools are scaled to zero while the replacement
DigitalOcean fleet provides persistent `general` capacity. Keeping the
visibility-based merge-gate routing from ADR 0033 would leave every Verjson PR
merge gate queued without an eligible runner.

Delivery speed is the immediate priority. The organization accepts a temporary
reduction in host isolation for merge-gate processing, while retaining an
explicit restoration record in issue #204.

## Decision

Route Verjson-owned AI merge-gate preflight and review jobs through
`["self-hosted","general"]` for both public and private repositories.

Do not apply `isolated` labels to persistent hosts; those labels assert
properties the DigitalOcean general fleet does not provide.

Keep runner capacity organization-isolated across both control planes:

- Verjson runners use the `verjson` DigitalOcean context and register only to
  the `Verjson` GitHub organization.
- Tequity runners use the `tequity` DigitalOcean context and register only to
  the `tequityapp` GitHub organization.
- Reusable cross-organization callers continue supplying labels for their own
  organization-local fleet.

## Consequences

Verjson merge gates can run immediately on the DigitalOcean general fleet.
Public PR gate processing temporarily shares persistent hosts with other
Verjson work and therefore lacks the disposable-host boundary established by
ADR 0033.

Issue #204 must restore disposable public-PR capacity and a separate privileged
gate lane, then supersede this temporary decision with a new ADR.
