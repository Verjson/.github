# 0179 — Confine every App private key, not only the three canonical roles

- **Date:** 2026-09-14
- **Status:** Accepted
- **Issue:** [#1285](https://github.com/Verjson/.github/issues/1285)
- **Scope:** Source-only. This change creates no environment, moves or deletes no
  secret, edits no ruleset and alters no workflow's runtime behavior.

## Context and evidence

ADR 0166 established that only an environment secret confines a GitHub App private
key, and ADR 0171 corrected its secret transport. Both decisions are scoped to three
roles — release, merge and AI review — and so is everything built on them: the
required reusable inputs, the `app-key-environment.yml` policy preflight, the
`ROLES` table in `scripts/app-key-environment-audit.py`, and the rollout runbook.

The CI gate that proves the contract, `scripts/ci-gate/app-key-environment.test.py`,
enumerated a hand-written dictionary of six workflow names. Enumerating the workflow
directory instead, on 2026-09-14, found **nine** App private keys bound across
seventeen jobs. Four were outside the contract's field of view:

| Secret | Bound by | Environment |
| --- | --- | --- |
| `RUNNER_DEPLOY_{CODE,SECURITY,AI}_REVIEW_APP_PRIVATE_KEY` | `container-deployment-review-producer` | fixed, caller-owned publisher environment |
| `GH_RUNNER_REGISTRATION_APP_PRIVATE_KEY` | `container-deployment` | fixed `production`, caller-owned |
| `RENOVATE_COMPATIBILITY_APP_PRIVATE_KEY` | `capability-floor-observe`, `dependency-supersession-observe`, `dependency-supersession-reconcile`, `renovate-compatibility-reconcile`, `renovate-grouping-plan` | **none** |
| `DEPENDENCY_SUPERSESSION_APP_PRIVATE_KEY` | `dependency-supersession-reconcile` | **none** |

Authenticated read-only metadata queries on 2026-09-14 established the storage side.
`Verjson` holds thirteen organization secrets; `Verjson/.github` holds zero repository
secrets and four environments. `RENOVATE_COMPATIBILITY_APP_PRIVATE_KEY` and
`DEPENDENCY_SUPERSESSION_APP_PRIVATE_KEY` are organization secrets at visibility
`all`, bound by jobs that request no environment. That is the #1285 exposure exactly
as the issue proved it: four of those six jobs are `workflow_dispatch`-triggered, and
a branch copy of any of them — or any new `on: push` workflow on a writer's branch —
reads the key with no review.

Two further facts came out of the same reads. The reviewed manifest
`config/org-actions-secret-policy.json` listed nine of the thirteen live organization
secrets, so `scripts/org-secret-scope-audit.py` had failed nightly since at least
2026-09-08 with a generic `manifest mismatch` naming `DEPENDENCY_SUPERSESSION_APP_PRIVATE_KEY`,
`RELEASE_APP_PRIVATE_KEY`, `RENOVATE_COMPATIBILITY_APP_PRIVATE_KEY` and
`REWORK_RECONCILE_TOKEN`. A stale manifest does not merely under-report: it converts
the organization's only standing credential-scope control into a check nobody can
read. And the manifest had no way to say *this secret must not exist*, which is the
one statement #1285's remedy actually needs.

## Decision

**1. The App-key contract's scope is every App private key a canonical workflow binds,
declared in `config/app-key-roles.json`.** Each entry states its role, secret,
intended environment, confinement kind and the disposition of its broad organization
copy. Three confinement kinds are recognized, and no fourth is admitted silently:

- `canonical` — the consuming job selects a main-only role environment through a
  required reusable input and depends on the keyless `app-key-environment.yml`
  preflight. This is the ADR 0171 shape.
- `caller-owned` — the consuming job names a fixed environment that the *calling*
  repository owns and provisions, because a reusable workflow's `environment:`
  resolves in the caller. No organization copy exists.
- `unconfined` — the key is readable from any non-fork ref. This is an exposure
  under remediation, not a supported state; an entry must name its tracking issue.

**2. The CI gate enumerates the workflow directory, not a list.** The manifest and
`.github/workflows` must agree in both directions, so adding an App-key binding
without declaring its confinement fails CI, and declaring a key no workflow binds
fails too. This is the control whose absence let the four keys above accumulate.

**3. The operator audit reports broad copies of every declared key.** Previously
`scripts/app-key-environment-audit.py` intersected live secret metadata with the
three canonical keys, so it could return `compliant` for a repository still holding
broad copies of the other six. A closure proof with a blind spot is worse than none.

**4. The organization secret policy gains a `withdrawn` target visibility.** It means
the organization copy must not exist. An absent withdrawn secret is conformance; a
present one fails with a message naming the broad copy rather than a generic manifest
mismatch. The five App private keys under #1285 are declared `withdrawn`, so the
nightly audit is now the standing tracker for the remaining exposure. Policy shape is
validated for every manifested secret, not only those present live, because a
withdrawn entry is normally absent and would otherwise never be checked.

## Trade-off accepted: no new environment binding here

The obvious next step — adding `environment: renovate-compatibility-app` to the five
unconfined jobs — is deliberately **not** taken in this change. GitHub creates a
referenced environment implicitly, with no protection rules, so the binding would
resolve the same broad organization secret while displaying a deployment record that
reads as confinement. Adding the `app-key-environment.yml` preflight instead would
hard-fail those workflows until an operator provisions the environment. Either way the
source change would be asserting a control that does not yet exist, which is the
failure mode the 2026-09-10 sequencing (provision, then activate) exists to prevent.

So the binding waits on provisioning, and the exposure is declared rather than
implied. The cost is that `renovate-compatibility-app` and `dependency-supersession-app`
remain unconfined until the operator step below; the benefit is that no artifact in
this repository claims otherwise, and CI now refuses to let a tenth key join them.

## Operator steps this decision does not perform

1. For `renovate-compatibility` and `dependency-supersession`, create the role
   environment in `Verjson/.github` with
   `{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}`
   and exactly one policy, `{"name":"main","type":"branch"}`.
2. Store each key as an environment secret of its role environment from a secure local
   file, then bind the environment and the keyless preflight in a follow-up source
   change, exactly as the three canonical roles were sequenced.
3. Withdraw each organization copy only after every reader is migrated. The nightly
   `org-secret-scope-audit` will turn green for that key on withdrawal and not before.
4. Narrow `DEEPSEEK_API_KEY`, `OPENAI_API_KEY` and `REWORK_RECONCILE_TOKEN` to their
   reviewed selected grants. These are pre-existing drifts this change surfaces
   precisely rather than introduces.

## Relationship to ADR 0166 and ADR 0171

This decision extends their scope; it does not reverse either. ADR 0166's transport
assumption remains superseded by ADR 0171, and ADR 0171's `secrets: inherit` contract,
required role inputs and absolute-pin requirement for the required-workflow entrypoint
are unchanged.
