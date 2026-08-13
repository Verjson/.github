# 0097 — Extend secretless Node validation to trusted refs

- **Date:** 2026-08-12
- **Issue:** [Verjson/.github#761](https://github.com/Verjson/.github/issues/761)
- **Category:** package credentials / trusted-ref execution — **sensitive class**
- **Status:** Accepted

## Context

[ADR 0086](../0086-secretless-node-pr-validation/README.md) separated private
dependency acquisition from pull-request code, and
[ADR 0095](../0095-bounded-secretless-node-cache-transfer/README.md) reduced the
handoff to exact private cache blobs plus one immutable auxiliary sparse tree.
The canonical mode admitted only same-repository pull requests. Its normal
trusted-ref route instead ran `npm ci` with a package token, omitted the
auxiliary source, and could not reproduce the reviewed rebuild and script plan.

A private consumer needs post-merge and direct-push validation even when branch
protection cannot enforce review. Treating a writer-authorized push as trusted
does not justify running repository lifecycle or consumer scripts with package,
Git, cloud, or OIDC credentials. A handwritten push workflow would also fork the
canonical package allowlist, auxiliary identity, audit, and smoke boundaries.

## Decision

Add an opt-in `secretless-trusted-ref` input to `node-ci.yml`. It reuses the
same acquisition job, exact package and scope policy, lifecycle-script-free
private cache population, 80 MiB identity-bound transfer, optional immutable
auxiliary sparse tree, credential scrub, lifecycle rebuild allowlist, ordered
script plan, and exact artifact cleanup as `secretless-pr`.

Keep the event modes mutually exclusive. `secretless-pr` continues to admit only
same-repository `pull_request` events and reject forks. The trusted-ref mode
admits only `push` and explicit `workflow_dispatch`; it rejects pull requests,
`pull_request_target`, schedules, and every other event before package-token
use. A caller must expose PR and trusted-ref execution as separate conditional
jobs and explicitly map only `NODE_AUTH_TOKEN`; inherited secrets are outside
the contract.

The token-bearing acquisition job remains on the isolated lane. It may parse
repository-controlled lock and pin data, but its fixed canonical steps execute
no dependency lifecycle, repository hook, or consumer script. Exact protected
repository variables bind any non-default package policy and auxiliary identity,
so pushed input cannot expand what the token may acquire. The trusted-ref build
job follows the normal trusted runner route or an explicit caller runner, but
checkout credentials are not persisted and package, GitHub, cloud, and OIDC
paths are cleared through the job environment before `npm ci --ignore-scripts`,
approved rebuilds, or consumer scripts.

Bypass stability-days deferral for `push` only. A stale status attached to a
pushed commit cannot suppress post-merge or direct-ref validation. Manual
dispatch retains its existing explicit bypass, while every other event keeps
the eligibility action's prior status-check behavior.

## Consequences

- PR behavior and runner isolation are unchanged unless the new input is set.
- Trusted pushes validate the same private package bytes, auxiliary commit,
  rebuild allowlist, and ordered audit/smoke plan without exposing acquisition
  credentials to repository-controlled execution.
- A repository writer can change code on a pushed ref, but that code runs only
  after credential removal. Package and auxiliary acquisition remain limited by
  protected repository policy and immutable lock or commit identities.
- Callers need two visible event-gated jobs and the `actions: write`,
  `contents: read`, and `statuses: read` permissions for both reusable
  invocations.
- Secretless modes still reject schema submodules and project `.npmrc` files;
  consumers needing those must use another reviewed canonical contract.

## Adoption

Pin both caller jobs to one 40-hex `Verjson/.github` commit and pass identical
package scopes, package names, auxiliary source, rebuild packages, and script
plan. Use `secretless-pr: true` only in the `pull_request` job and
`secretless-trusted-ref: true` only in the `push`/`workflow_dispatch` job. If the
adoption also advances changelog artifacts, regenerate the workflow, renderer,
contract test, and release caller together with
`Verjson/.github/scripts/gen-changelog-caller.sh` at that same immutable SHA.

## Rollback

Disable `secretless-trusted-ref` to return trusted refs to the existing
credentialed install route, or remove the trusted-ref caller job while retaining
secretless PR validation. Neither rollback changes callers that omit the new
input.
