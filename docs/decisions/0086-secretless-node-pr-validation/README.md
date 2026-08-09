# 0086 — Separate Node dependency acquisition from secretless PR execution

- **Date:** 2026-08-09
- **Issue:** [Verjson/.github#680](https://github.com/Verjson/.github/issues/680)
- **Category:** package credentials / untrusted PR execution — **sensitive class**
- **Status:** Accepted

## Context

The canonical Node workflow previously requested `packages: read` on its build job and
installed private dependencies in the same job that later executed repository-controlled
build and test scripts. A caller that omitted that permission failed when the reusable
workflow started, while granting it made a package-capable job token available in the PR
execution boundary. Passing `NODE_AUTH_TOKEN` into `npm ci` in that job exposed a still
stronger cross-repository package credential.

Private consumers need approved `@verjson` contracts during validation. Running lifecycle
scripts with a package token, routing PRs to persistent capacity, or treating package names
in a PR-controlled lockfile as authorization would each collapse a credential boundary.

## Decision

Add an opt-in `secretless-pr` mode with two jobs. An acquisition job on the isolated
untrusted lane (with a GitHub-hosted fallback and no trusted-lane fallback) checks out
the PR without persisted Git credentials, accepts only an explicitly mapped package
token, and validates a version 2 or 3 package lock before network access. Every resolved
`@verjson` package must exactly match the caller's allowlist and its GitHub Packages
download URL. It rejects repository-controlled `.npmrc` files and forces npm to use a
job-created user config outside the checkout, with the token interpolated only for
`npm.pkg.github.com`. The job runs `npm ci` with lifecycle scripts, audit, and funding
requests disabled, archives only `node_modules`, and retains that artifact for one day.

The build job also uses only the isolated untrusted lane or hosted fallback, overriding
any caller runner selection. It downloads the artifact without package permission, does
not run an install, does not initialize submodules, persists no checkout credential, and
clears package, Git, cloud, and OIDC credential paths before any repository-controlled
command. Secretless mode is restricted to same-repository `pull_request` events and
rejects forks and schema submodules. It never uses `pull_request_target` to check out PR
code. The caller maps only `NODE_AUTH_TOKEN`; `secrets: inherit` is outside the documented
contract.

The existing route remains the default and keeps its authenticated install. The package
secret, not the job token, has always performed cross-repository acquisition, so the
build job no longer requests an unused package capability. A caller's existing
`packages: read` grant remains accepted, while secretless calls start without it.

## Consequences

- PR code receives approved dependency bytes without receiving the credential used to
  acquire them.
- A dependency addition requires an explicit caller allowlist review and canonical caller
  update; lockfile names alone never grant access.
- Lifecycle-dependent packages cannot use this mode unless their published artifact is
  changed to work without install scripts. This is an intentional acquisition constraint.
- Private schema submodules require a separately designed trusted acquisition contract;
  they are not silently admitted here.
- The artifact is a same-run handoff, not a shared dependency cache, and expires after one
  day.

## Rollback

Callers can omit `secretless-pr` to use the unchanged credentialed path. Reverting the
implementation removes the opt-in mode without changing existing caller behavior.
