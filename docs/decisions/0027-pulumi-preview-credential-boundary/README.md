# 0027 — Pulumi validation and live preview use separate credential boundaries

- **Date:** 2026-07-27
- **Issue:** Verjson/.github#151
- **Category:** reusable-workflow security posture (IAM/OIDC · secrets · runner topology)

## Context

The reusable `pulumi-ci.yml` ran caller-supplied install and validation commands
in the same job that held `pull-requests: write`, `id-token: write`, package and
Git tokens, and live GCP/Pulumi credentials. Its checkout also used
`persist-credentials: true` by default. A fork caller could cap permissions and
would not receive repository secrets, but the reusable itself did not enforce a
credential boundary. On a same-repository PR, caller-controlled commands and
dependency lifecycle scripts ran before preview with every job credential
available.

This blocks the Tequity self-hosted-runner boundary tracked by
tequityapp/tequity-docs#28 (ADR-0039) and tequityapp/tequity-platform#62. The
shared reusable must make the safe path structural rather than depend on every
caller reproducing an event/secret guard correctly.

## Decision

1. **Validation is a separate, credential-free job.** It defaults to
   `ubuntu-latest`, has only `contents: read`, uses checkout with
   `persist-credentials: false`, and receives no declared workflow secret.
   Caller-supplied `install-command` and `validate-command` inputs exist only in
   this job. The command step also ignores system/global Git configuration,
   points npm at a new empty user config, disables interactive Git prompts, and
   unsets known GitHub, OIDC, npm, Git, GCP, and Pulumi credential variables
   before evaluating either command.
2. **Live preview has explicit, fail-closed admission.** A fixed-script,
   GitHub-hosted job emits `admitted=true` only for `push`, or for
   `pull_request` whose head repository exactly matches `github.repository`, and
   only when the GCP Workload Identity provider, GCP service account, and Pulumi
   backend token are all present. Fork PRs, unknown events, and any missing
   cloud credential produce `false`. Admission runs only after validation
   succeeds, and preview depends on both jobs.
3. **Only the admitted preview job gets privileged permissions.** It holds
   `id-token: write` for GCP Workload Identity and `pull-requests: write` for
   Pulumi's same-repository PR comment. Both its checkout and the validation
   checkout disable credential persistence.
4. **Package/Git credentials are step-scoped before cloud auth.** The trusted
   preview path installs with the workflow-owned fixed `npm ci`, never a caller
   command. `NODE_AUTH_TOKEN`, `VERJSON_GIT_TOKEN`, and Git's in-memory
   credential configuration exist only for that install step. GCP auth happens
   afterward, and the Pulumi action receives only its backend token plus the
   short-lived GCP credentials.
5. **Third-party actions are immutable.** Checkout, setup-node, GCP auth, and
   Pulumi actions use reviewed full commit SHAs with version comments. Renovate
   may propose ordinary reviewed pin updates.

## Consequences

- Fork PRs and secret-less callers still receive the compile/test gate, but they
  cannot reach live cloud preview even if an event payload is surprising.
- A same-repository PR is treated as trusted for live preview because only users
  able to update a branch in that repository can supply its code. Widening this
  admission set requires a new security review and an amendment or superseding
  ADR.
- Credential-free validation can no longer consume private packages or private
  Git dependencies. Such repositories must expose a public validation path; the
  trusted preview job can still install private dependencies for the live
  preview after admission.
- `validation-runner` remains overrideable for callers with a dedicated
  ephemeral pool, but credential scrubbing is enforced even when a caller
  selects a persistent runner.
- The extracted shell test executes the admission truth table for fork PR,
  same-repository PR, push, missing-secret, `pull_request_target`, and other
  unlisted secret-bearing events; it also pins job permissions, command
  placement, credential scrubbing, checkout behavior, install/auth order,
  action SHAs, and the existing comment-on-push no-op contract.
