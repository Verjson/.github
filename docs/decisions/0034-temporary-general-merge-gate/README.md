# 0034 — Temporarily route Verjson merge gates through general runners

- **Date:** 2026-07-29
- **Issue:** [Verjson/.github#204](https://github.com/Verjson/.github/issues/204)
- **Temporarily supersedes:** ADR 0033 for AI merge-gate and `.github`
  repository validation routing

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
Route this repository's shell/actionlint validation through the same pool so
the policy change can validate without isolated GCP capacity.
Set `VERJSON_RUNNER_ISOLATED` to `["self-hosted","general"]`, make that
organization variable visible to public repositories, and permit public
Verjson repositories in the selected general runner group for the duration of
the exception.

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

Issue #204 must restore disposable public-PR capacity, a separate privileged
gate lane, and isolated execution for this repository's shell/actionlint
validation. It must also restore `VERJSON_RUNNER_ISOLATED` and remove public
visibility from that organization variable, then remove public repository
access from the persistent general runner group before superseding this
temporary decision with a new ADR.

## 2026-07-30 amendment — route all Verjson workflows through general

Issue [#212](https://github.com/Verjson/.github/issues/212) expands the temporary
exception after literal isolated selectors and visibility-based reusable
defaults left required checks queued with no eligible runner. Until CI security
hardening is revisited, every Verjson-owned workflow defaults to the online
provider-neutral `[self-hosted, general]` lane. External reusable-workflow
callers retain their GitHub-hosted portability path, and explicit caller runner
overrides remain available.

This deliberately pauses ADR 0033's public/private visibility split across the
whole reusable workflow package, not only merge gates. Persistent general hosts
therefore run public Verjson PR validation during the exception. Issue #204
remains the restoration record for disposable public-PR capacity and the
stronger trust boundary.
